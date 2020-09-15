require 'bundler'
require 'net/http'
require 'uri'
require 'json'
require 'net/ssh'
require 'yaml'

@secrets_hash = YAML.load(File.read("secrets.yml"))
@slack_webhook_url = @secrets_hash["slack_webhook_url"]

def send_slack_message message
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
        result = ssh.exec!("echo \"#{@secrets_hash["password"]}\" | sudo -S zcat -f /var/log/nginx/access.log*")
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
            matched_records << {:timestamp => tokenized_line[3].tr('[', ''), :ip => tokenized_line[0]} 
        end
    end
    return matched_records.sort_by! {|k| k[:timestamp]}.uniq! {|pair| pair[:ip]}.reverse!
end

def geo_api_lookup pair
    uri = URI.parse("https://json.geoiplookup.io/#{pair[:ip]}")
    response = Net::HTTP.get_response(uri)
    response_json = JSON.parse(response.body)
    {"timestamp" => pair[:timestamp], "ip" => response_json["ip"], "city" => response_json["city"], "region" => response_json["region"], "country_name" => response_json["country_name"]}
end

def read_previous_results 
    filename = "previous_results.json"
    if File.exist?(filename)
        file = File.open filename
        return JSON.load file
    else 
        return []
    end
    
end

def write_result data
    File.write('./previous_results.json', JSON.dump(data))
end

def new_records_exist? latest_results, previous_results
    (latest_results - previous_results).size != 0
end

#log_strings = File.open("test.log")
log_strings = fetch_nginx_logs_from_remote
matched_records = match_cv_records(log_strings)

latest_results = []
matched_records.each do |pair|
    # puts "Processing pair: #{pair.inspect}"
    response_hash = geo_api_lookup(pair)
    latest_results << response_hash

    # break #Uncomment this debug statement to stop after first loop

    sleep 0.5
end

previous_results = read_previous_results
if new_records_exist? latest_results, previous_results
    formatted_results = latest_results.join("\n")
    puts "Found new records. Sending notifying Slack."
    puts "Latest records dump: #{formatted_results.inspect}"
    send_slack_message("New GET record(s) for 'http://ericwryan.com/cv/': \n #{formatted_results}")
else
    puts "No new records found."
end

puts "Writing latest results."
write_result latest_results

puts "Done. Exiting."
exit

