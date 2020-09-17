require 'bundler'
require 'net/http'
require 'uri'
require 'json'
require 'net/ssh'
require 'yaml'

@secrets_hash = YAML.load(File.read("secrets.yml"))
@slack_webhook_url = @secrets_hash["slack_webhook_url"]

def send_slack_message message
    puts "Sending Slack message: '#{message.inspect}'"
    uri = URI.parse(@slack_webhook_url)
    request = Net::HTTP::Post.new(uri)
    request.content_type = "application/json"
    request.body = JSON.dump({
      "text" => message
    })
    
    req_options = {
      use_ssl: uri.scheme == "https",
    }
    
    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end
    
    return response
end

def fetch_nginx_logs_from_remote
    puts "Fetching nginx logs from remote: #{@secrets_hash["host"]}"
    ssh_result = ""
    Net::SSH.start(@secrets_hash["host"], @secrets_hash["user"], :password => @secrets_hash["password"]) do |ssh|
        result = ssh.exec!("echo \"#{@secrets_hash["password"]}\" | sudo -S zcat -f #{@secrets_hash["log_search_string"]}")
        ssh_result = result.to_s
    end
    return ssh_result
end

def match_cv_records input
    puts "Searching for matching records."
    matched_records = [] #[{:timestamp => "1234", ip => "1.1.1.1"}, ...]
    input.split("\n").each do |line|                   
        tokenized_line = line.split
        if (tokenized_line[6] == "/cv/" || tokenized_line[6] == "/cv") && tokenized_line[5] == "\"GET"
            puts "\tFound match to evaluate: \t IP: #{tokenized_line[0]}"
            matched_records << {"timestamp" => tokenized_line[3].tr('[', ''), "ip" => tokenized_line[0]} 
        end
    end
    return matched_records.sort_by! {|k| k["timestamp"]}.uniq! {|pair| pair["ip"]}.reverse!
end

def geo_api_lookup pair
    puts "\tProcessing Geo IP lookup for: #{pair.inspect}"
    uri = URI.parse("https://json.geoiplookup.io/#{pair["ip"]}")
    response = Net::HTTP.get_response(uri)
    response_json = JSON.parse(response.body)
    sleep 0.5
    {"timestamp" => pair["timestamp"], "ip" => response_json["ip"], "city" => response_json["city"], "region" => response_json["region"], "country_name" => response_json["country_name"]}
end

def read_previous_results filename
    puts "Reading from file: '#{filename}'"
    if File.exist?(filename)
        file = File.open filename
        return JSON.load file
    else 
        return []
    end
    
end

def write_result data, filename
    puts "Writing to file: '#{filename}'"
    File.write(filename, JSON.dump(data))
end

def new_records_exist? latest_results, previous_results
    # puts "DEBUG: latest results: #{latest_results.inspect}"
    # puts "DEBUG: previous results: #{previous_results.inspect}"
    (latest_results - previous_results).size != 0
end

#log_strings = File.open("test.log")
log_strings = fetch_nginx_logs_from_remote
previous_results = read_previous_results './previous_results_raw.json'
latest_results = match_cv_records(log_strings)

if new_records_exist? latest_results, previous_results
    puts "Found new records. Performing Geo Lookups"
    new_records = latest_results - previous_results
    new_records_with_geo = new_records.map {|r| geo_api_lookup r}  
    send_slack_message "New matching record found in nginx logs: \n#{new_records_with_geo.join("\n")}"
    write_result(new_records_with_geo, './previous_results_geo.json')
else
    puts "No new records found."
end

write_result(latest_results, './previous_results_raw.json')

exit

