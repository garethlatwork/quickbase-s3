
require_relative 'file_mover_job'
require 'tzinfo'

class FileMoverJobLauncher

  def initialize(params,move_files)
    @params = params.dup
    @move_files = move_files
  end	

  def config_iron_worker
     IronWorker.configure { |iwconfig|
        iwconfig.token = @params["iw_token"]
        iwconfig.project_id = @params["iw_project_id"]
     }
  end

  def launch_file_mover_job
    @params["copy_files"] = @move_files ? "false" : "true"
     config_iron_worker
     fmj = FileMoverJob.new
     fmj.params = @params.dup
     sw_params = get_sw_params(@params)
     if @params["debug_ironworker"] == "true"
       fmj.run_local
     elsif sw_params
       fmj.schedule(sw_params)
     else  
       fmj.queue
    end
  end	

  def get_sw_params(params)
    sw_params = {}
    if params["start_time"] and params["start_time"] != "ASAP"
      hour, am_pm = params["start_time"].split(/ /)
      hour = hour.to_i
      hour += 12 if am_pm == "PM"
      if params["timezone"]
        tz = TZInfo::Timezone.get(params["timezone"])
        current_time = tz.now
        current_hour = current_time.hour
        if hour > current_hour
          sw_params[:start_at] = current_time + ((hour - current_hour)*60*60) 
        elsif hour < current_hour
          sw_params[:start_at] = current_time + (((hour+24) - current_hour)*60*60)
        else  
          sw_params[:start_at] = current_time
        end
        sw_params[:start_at] -=  (current_time.min() * 60)
        sw_params[:start_at] -=  (current_time.sec)
      end  
    end
    if params["frequency"] and params["frequency"] != "N/A - Don't Repeat"
      if params["frequency"] == "Hour"
        sw_params[:run_every] = (60*60)
      elsif params["frequency"] == "Day"
        sw_params[:run_every] = (60*60*24)
      elsif params["frequency"] == "Week"
        sw_params[:run_every] = (60*60*24*7)
      else 
        number, units = params["frequency"].split(/ /)
        number = number.to_i
        if units == "minutes"
          sw_params[:run_every] = (number*60)
        elsif units == "hours"
          sw_params[:run_every] = (number*60*60)
        elsif units == "days"
          sw_params[:run_every] = (number*60*60*24)
        end    
      end    
    end
    sw_params = nil if sw_params.empty?
    sw_params
  end  

end
