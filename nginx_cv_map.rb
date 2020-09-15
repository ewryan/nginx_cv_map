require 'bundler'
require 'net/http'
require 'uri'
require 'json'
require 'net/ssh'
require 'yaml'


secrets_hash = YAML.load(File.read("secrets.yml"))

ssh_result = ""
Net::SSH.start(secrets_hash["host"], secrets_hash["user"], :password => secrets_hash["password"]) do |ssh|
    result = ssh.exec!("echo \"#{secrets_hash["password"]}\" | sudo -S zcat -f /var/log/nginx/access.log*")
    ssh_result = result.to_s
end

cv_lines = [] #[{:timestamp => "1234", ip => "1.1.1.1"}, ...]

#Tokenize Log Output
# File.open("test.log").each do |line|      #uncomment this line to use test.log file
ssh_result.split("\n").each do |line|                   #uncomment this line to use ssh result
    tokenized_line = line.split
    if (tokenized_line[6] == "/cv/" || tokenized_line[6] == "/cv") && tokenized_line[5] == "\"GET"
        cv_lines << {:timestamp => tokenized_line[3].tr('[', ''), :ip => tokenized_line[0]} 
    end
end

# #Sort and remove duplicate IP Entries
cv_lines.sort_by! {|k| k[:timestamp]}.uniq! {|pair| pair[:ip]}.reverse!

cv_lines.each do |pair|
    puts "Processing pair: #{pair.inspect}"
    uri = URI.parse("https://json.geoiplookup.io/#{pair[:ip]}")
    response = Net::HTTP.get_response(uri)
    response_json = JSON.parse(response.body)

    puts "#{pair[:timestamp]}\t #{response_json["ip"]} \t #{response_json["city"]}, #{response_json["region"]}, #{response_json["country_name"]}\n\n"

    # break #Uncomment this debug statement to stop after first loop

    sleep 0.5
end

