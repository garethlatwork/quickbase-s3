
require 'gmail_sender'
require 'quickbase_client'
require 'logger'
require 'right_aws'
require 'i18n'
require 'cgi'
require 'fileutils'
require_relative 's3client'

REPORT_NAME = "z-Files->S3"
LOG_FILE = "file_mover.log"
LOGFILE_AGE = "daily"
TMP_DIR = "./tmp"
S3_URL = " - s3 url"
S3_FILE = " - s3 file"
DOWNLOAD_URL = "https://quickbase-s3.heroku.com/download_file?key="
REALM = "www"
RFID = "3"
GMAIL_SUBJECT = "QuickBase to S3 File Mover Log"
QB_LOG_FILE_TABLE = "S3 File Mover Log Files"
QB_LOG_FILE_FIELD = "Log File"
QB_LOG_ENTRY_TABLE = "S3 File Mover Log Entries"
QB_LOG_ENTRY_FIELD = "Log Entry"
S3_KEY_FORMAT = "%{realm} table: %{table_name} (id: %{table_id})/record: %{record_id}, field: %{field_name}, (id: %{field_id}), time: %{time}/%{file_name}"

class FileMover

    def initialize(configuration)
      @config = configuration.dup
      @qbc = QuickBase::Client.init(@config)
      @qbc.cacheSchemas=true
      @qbc.apptoken = @config["apptoken"]
      @qbc.printRequestsAndResponses = debug_quickbase?
      @qbc.getUserInfo
      if @qbc.requestSucceeded
        @s3c = S3Client.new(@config)
        @s3c.create_bucket
        @quickbase_log_fields_added = false
      else
        log "Connecting to QuickBase: #{@qbc.lastError}", true
      end
    end  

    def method_missing(sym)
      m = sym.to_s
      if m.end_with?("?")
        m[-1,1]=""
        ret = config?(m)
      else  
        ret = @config[m]
      end
      ret
    end  

    def copy_or_move_files_to_s3
      log "Starting copy or move."

      report_name = get_report_name
      log "Using Report '#{ report_name}' to find files in QuickBase."

      do_copy_files = true
      do_copy_files = copy_files? if @config["copy_files"] 
      if do_copy_files
        log "Files will be copied (not moved) from QuickBase to Amazon S3."
      else
        log "Files will be moved (not copied) from QuickBase to Amazon S3."
      end

      realm = realm || REALM
      log "Your QuickBase tables are expected to be under https://#{realm}.quickbase.com." 
      
      download_url = download_url || DOWNLOAD_URL 
      log "File download URLs will start with '#{download_url}'." 

      s3_url_field_name = s3_url_field_name_addition || S3_URL
      s3_file_field_name = s3_file_field_name_addition || S3_FILE
      log "The S3 URL and File field names in your QuickBase tables will end with '#{s3_url_field_name}', '#{s3_file_field_name}'." 

      total_files_copied = 0 
      total_files_moved = 0

      get_tables.each{|dbid| 

        table_name = @qbc.getTableName(dbid)
        log "Processing table '#{table_name}' (#{dbid})."
        
        fields, query, slist = get_report_params(dbid,report_name,table_name)
        create_s3_fields(dbid,fields,s3_url_field_name,s3_file_field_name)
        tmp_dir = create_tmp_dir

        files_copied = 0 
        files_moved = 0

        @qbc.iterateRecords(dbid,fields.keys,query,nil,nil,fields.values,slist){|record|

          record_id = nil  
          record.each{|field_name,field_value| record_id = field_value if fields[field_name] == RFID }

          if record_id
            if record.count > 1
              record.each{|field_name,field_value| 
                unless fields[field_name] == RFID 

                  ret, file_contents = @qbc.downloadFile(dbid,record_id,fields[field_name])
                  if ret and file_contents and file_contents.length > 0

                    writable_file_name = local_file_name(field_value)  
                    File.open("#{tmp_dir}/#{writable_file_name}","wb"){|f|f.write(file_contents);f.flush;f.close}
                    log "File '#{field_value}' downloaded successfully from QuickBase record '#{record_id}', field '#{field_name}' to temporary folder '#{tmp_dir}'."
                    log "QuickBase file download URL is: #{@qbc.downLoadFileURL} "
                    
                    s3key = format_s3_key(realm,table_name,dbid,record_id,field_name,fields,field_value)
                    ret = @s3c.upload_file("#{tmp_dir}/#{writable_file_name}",s3key) 
                    if ret.is_a?(Hash) and ret["etag"]
                      log "Successfully uploaded file to Amazon S3 key '#{s3key}', from QuickBase record '#{record_id}', field '#{field_name}'."
                      files_copied += 1
                      download_url = "#{download_url}#{s3key.dup}"
                      log "S3 download URL is: #{download_url} "
                      update_quickbase_record(dbid,record_id,field_name,field_value,s3_url_field_name,s3_file_field_name,download_url,do_copy_files,fields,files_moved)
                    else
                      log "Uploading file to Amazon S3 from QuickBase record '#{record_id}', field '#{fields[field_name]}': #{ret}.", true
                      log "(File not removed from QuickBase)" unless do_copy_files
                    end  
                  else
                    log "Downloading file from QuickBase record '#{record_id}', field '#{fields[field_name]}': #{@qbc.lastError}", true
                  end  
                end
              }
            else
              log "Table '#{table_name}' (#{dbid}) will not be processed: report '#{report_name}' does not contain any File Attachment fields."
              break
            end  
          else
            log "Table '#{table_name}' (#{dbid}) will not be processed: unable to determine the record ID for records."
            break
          end  
        }
        if do_copy_files
          log "#{files_copied} files copied for table '#{table_name}' (#{dbid})."
          total_files_copied += files_copied 
        else  
          log "#{files_moved} files moved for table '#{table_name}' (#{dbid})."
          total_files_moved += files_moved
        end
      }
      remove_temp_files if remove_temp_files?
      total_files_processed = "(#{total_files_copied} files copied, #{total_files_moved} files moved)"
      do_copy_files ? log("Copy complete #{total_files_processed}.") : log("Move complete #{total_files_processed}.")
      email_log_file if email_log_file?
      upload_log_file_to_quickbase if upload_log_file_to_quickbase?
      rescue StandardError => exception
      log exception, true
    end

    def update_quickbase_record(dbid,record_id,field_name,field_value,s3_url_field_name,s3_file_field_name,download_url,do_copy_files,fields,files_moved)
      @qbc.editRecord(dbid, record_id,{"#{field_name}#{s3_url_field_name}" => download_url, "#{field_name}#{s3_file_field_name}" => field_value.dup})
      if @qbc.requestSucceeded 
        unless do_copy_files
          @qbc.removeFileAttachment(dbid,record_id,field_name)
          if @qbc.requestSucceeded 
            log "File Attachment removed from QuickBase record '#{record_id}', field '#{fields[field_name]}'."
            files_moved += 1
          else  
            log "Removing File Attachment from QuickBase record '#{record_id}', field '#{fields[field_name]}': #{@qbc.lastError}", true
          end  
        end
      else
        log "Editing QuickBase record '#{record_id}', field '#{fields[field_name]}': #{@qbc.lastError}", true
      end  
    end  

    def get_report_params(dbid,report_name,table_name)
      log "Retrieving information for the '#{report_name}' report from table '#{table_name}' (#{dbid})."
      fields = {}
      clist = @qbc.getColumnListForReport(nil,report_name)
      slist = @qbc.getSortListForReport(nil,report_name)
      query = @qbc.getCriteriaForReport(nil,report_name)
      field_ids = []
      field_ids = clist.split(/\./) if clist
      field_ids << RFID unless field_ids.include?(RFID)
      field_ids.each{|field_id|
        field_name = @qbc.lookupFieldNameFromID(field_id)
        field_type = @qbc.lookupFieldTypeByName(field_name) 
        if field_type == "file" or field_id == RFID
          fields[field_name] =  field_id 
        end
      }
      return fields, query, slist
    end

    def create_s3_fields(dbid,fields,s3_url_field_name,s3_file_field_name)
      current_field_names = @qbc.getFieldNames(dbid) 
      fields.each{|field_name,field_value|
      next if field_value == RFID
        url_field_name = "#{field_name}#{s3_url_field_name}"
        unless current_field_names.include?(url_field_name)
          @qbc.addField(dbid,url_field_name,"url")
          error = @qbc.requestSucceeded ? "" : ": #{@qbc.lastError}"
          log "Adding URL field '#{url_field_name}' to table #{dbid}'#{error}.", (@qbc.requestSucceeded == false)
        end        
        file_field_name = "#{field_name}#{s3_file_field_name}"
        unless current_field_names.include?(file_field_name)
          @qbc.addField(dbid,file_field_name,"text")
          error = @qbc.requestSucceeded ? "" : ": #{@qbc.lastError}"
          log "Adding Text field '#{file_field_name}' to table '#{dbid}'#{error}.",  (@qbc.requestSucceeded == false)
        end
      }
    end  

    def get_tables
      log "Getting list of QuickBase tables to process..." 
      tables = get_table_ids
      filter_tables(tables)
      log "#{tables.count} tables will be processed."
      tables
    end

    def get_table_ids
      tables = []
      (1..100).each{|i|
        table_entry = "quickbase_table_#{i}"
        if @config[table_entry]
          config_value = @config[table_entry]
          if i == 1 and config_value and config_value == "ALL TABLES"
            grantedDBs = @qbc.grantedDBs
            tables = grantedDBs.map{|db|db.dbinfo.dbid} if grantedDBs
            break
          elsif QuickBase::Misc.isDbidString?(config_value)
            @qbc.getSchema(config_value)
            if @qbc.requestSucceeded
              child_tables = @qbc.getTableIDs(config_value)
              if child_tables
                log "Adding tables from the Application with the id '#{config_value}' (from the \"#{table_entry}\" configuration entry)."  
                tables += child_tables
              else    
                log "Adding Table '#{config_value}' (from the \"#{table_entry}\" configuration entry)."  
                tables << config_value
              end
            else
              log "'#{config_value}' is not an accessible QuickBase Aplication or Table ID (from the \"#{table_entry}\" configuration entry)." 
            end 
          else
            app_dbid = @qbc.findDBByName(config_value)
            if app_dbid
              log "Adding tables from the '#{config_value}' (#{app_dbid}) Application (from the \"#{table_entry}\" configuration entry)."  
              tables += @qbc.getTableIDs(app_dbid)
            else
              log "'#{config_value}' is not an accessible QuickBase Aplication (from the \"#{table_entry}\" configuration entry)." 
            end
          end
        end
      }
      tables
    end

    def filter_tables(tables)
      report_name = get_report_name
      tables.reject!{|table_dbid| 
        report_names = @qbc.getReportNames(table_dbid)
        exclude = (report_names.include?(report_name) == false) 
        if exclude
          log "Excluding table '#{table_dbid}' because it does not have a '#{report_name}' report."  
        end
        exclude
      }
    end  

    def create_tmp_dir
       tmp_dir = tmp_dir_name || TMP_DIR
       unless File.directory?(tmp_dir)
         Dir.mkdir(tmp_dir) 
         log "Local '#{tmp_dir}' folder created for files downloaded from QuickBase."
       end
       tmp_dir
    end  

    def config?(option)
      @config[option] and (@config[option] == true or @config[option] == "true")
    end  
      
    def remove_temp_files
       tmp_dir = tmp_dir_name || TMP_DIR
       FileUtils.rm_rf if File.directory?(tmp_dir)
       log "Local '#{tmp_dir}' temporary files folder removed."
    end

    def local_file_name(name)
      file_name = name.dup.strip
      file_name.gsub!(/\W/,"_")
      file_name
    end

    def get_report_name
      file_list_report_name || REPORT_NAME
    end  

    def format_s3_key(realm,table_name,dbid,record_id,field_name,fields,field_value)
      format_string = s3_key_format|| S3_KEY_FORMAT
      format_hash = {
        realm: realm.gsub(/\W/,"_"),  
        table_name: table_name.gsub(/\W/,"_"), 
        table_id: dbid, 
        record_id: record_id, 
        field_name: field_name.gsub(/\W/,"_"), 
        field_id: fields[field_name],
        time: Time.now,
        file_name: field_value
      }
      format_string % format_hash
    end  

    def log(msg,error=false)
      error ? log_error(msg) : log_info(msg)
    end  

    def log_error(error)
      puts "ERROR: #{error}" if debug?
      log_error_to_file(error) unless no_log_file? 
      email_msg(error,true) if email_errors_via_gmail?
      log_to_quickbase(error,true) if log_errors_to_quickbase?
    end

    def log_info(info)
      puts "INFO: #{info}" if debug?
      log_info_to_file(info) unless no_log_file?
      email_msg(info) if log_info_via_gmail?
      log_to_quickbase(info) if log_info_to_quickbase?
    end

    def log_to_quickbase(msg,error=false)
      add_quickbase_log_fields unless @quickbase_log_fields_added
      log_entry = error ? "Error: #{msg}" : msg
      get_qb_logger.addRecord(quickbase_log_entry_table_id,{quickbase_log_entry_field_name  || QB_LOG_ENTRY_FIELD => log_entry})
      rescue StandardError => exception
      puts_exception(exception,msg)
    end  

    def email_msg(msg,error=false)
      @gmail_sender ||= GmailSender.new(gmail_username, gmail_password)
      @gmail_subject ||= gmail_subject || GMAIL_SUBJECT
      subject = error ? "Error: #{@gmail_subject}" : @gmail_subject
      @gmail_sender.send({ :to => gmail_recipient || gmail_username, :subject =>  subject, :content => msg.to_s })
      rescue StandardError => exception
      puts_exception(exception,msg)
    end

    def email_log_file
      if @logger
        @logger.close
        logfile = logfile() || LOG_FILE
        if File.exist?(logfile)
          logfile_contents = IO.read(logfile)
          if logfile_contents and logfile_contents.length > 0
            @gmail_sender ||= GmailSender.new(gmail_username, gmail_password)
            @gmail_subject ||= gmail_subject || GMAIL_SUBJECT
            @gmail_sender.send({ :to => email_recipient || gmail_username, :subject =>  @gmail_subject, :content => logfile_contents })
          end
        end
      end
      rescue StandardError => exception
      puts_exception(exception)
    end

    def upload_log_file_to_quickbase
      if @logger
        @logger.close
        logfile = logfile() || LOG_FILE
        if File.exist?(logfile)
          add_quickbase_log_fields unless @quickbase_log_fields_added
          get_qb_logger.uploadFile(quickbase_log_file_table_id,logfile,quickbase_log_file_field_name || QB_LOG_FILE_FIELD)
        end
      end
      rescue StandardError => exception
      puts_exception(exception)
    end

    def add_quickbase_log_fields
      qbl = get_qb_logger
      if upload_log_file_to_quickbase?
        dbid = quickbase_log_file_table_id
        field = quickbase_log_file_field_name || QB_LOG_FILE_FIELD
        fid = nil
        if dbid
          qbl.getSchema(dbid)
          if qbl.requestSucceeded
            fid = qbl.lookupFieldIDByName(field,dbid)
          else
            dbid = nil 
          end
        end
        if dbid
          qbl.addField(dbid,field,"file") unless fid
        else  
          dbid, appdbid = qbl.createDatabase(QB_LOG_FILE_TABLE,QB_LOG_FILE_TABLE)
          if qbl.requestSucceeded
            qbl.addField(dbid,field,"file")
          else
            puts "Error: #{qbl.lastError}"
          end  
        end
        @config["quickbase_log_file_table_id"] = dbid
        @config["quickbase_log_file_field_name"] = field
      end  
      if log_errors_to_quickbase? or log_info_to_quickbase?
        dbid = quickbase_log_entry_table_id
        field = quickbase_log_entry_field_name || QB_LOG_ENTRY_FIELD
        fid = nil
        if dbid
          qbl.getSchema(dbid)
          if qbl.requestSucceeded
            fid = qbl.lookupFieldIDByName(field,dbid)
          else  
            dbid = nil
          end
        end
        if dbid
          qbl.addField(dbid,field,"text") unless fid
        else  
          dbid, appdbid = qbl.createDatabase(QB_LOG_ENTRY_TABLE,QB_LOG_ENTRY_TABLE)
          if qbl.requestSucceeded
            qbl.addField(dbid,field,"text")  
          else
            puts "Error: #{qbl.lastError}"
          end  
        end
        @config["quickbase_log_entry_table_id"] = dbid
        @config["quickbase_log_entry_field_name"] = field
      end  
      @quickbase_log_fields_added = true
    end  

    def log_error_to_file(error)
      get_file_logger.error(error)
      rescue StandardError => exception
      puts_exception(exception,error)
    end  

    def log_info_to_file(info)
      get_file_logger.info(info)
      rescue StandardError => exception
      puts_exception(exception,info)
    end  

    class MyLogFormatter < Logger::Formatter
      def call(severity, time, progname, msg)
        "%s, [%s#%d] %5s -- %s: %s\r\n" % [severity[0..0], format_datetime(time), $$, severity, progname, msg2str(msg)]
      end          
    end  

    def get_file_logger
      unless @logger
        @logger = Logger.new(logfile || LOG_FILE,  logfile_age || LOGFILE_AGE)
        @logger.formatter = MyLogFormatter.new
      end
      @logger
    end  

    def get_qb_logger
      @qb_logger_client ||= QuickBase::Client.init(@config)
      @qb_logger_client.cacheSchemas=true
      @qb_logger_client.printRequestsAndResponses = debug_quickbase?
      @qb_logger_client
    end  

    def puts_exception(e,msg=nil)
      puts msg if msg
      puts e
      puts e.backtrace
    end 

end

