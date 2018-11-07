require 'json'

def target_service(request, endpoints)
  url = /(http|https):\/\/#{request[:host]}:#{request[:port]}/
  url_with_version = /#{url}#{request[:path][/\/v[1-9](\.[0-9]+)?/]}/

  catalog_entry = match_service_url(endpoints, url_with_version)
  if catalog_entry.empty?
    catalog_entry = match_service_url(endpoints, url)
  end

  if catalog_entry.empty?
    puts "nothing found for url '#{url}'"
  else

    {
        type: catalog_entry[0]['type'],
        name: catalog_entry[0]['name']
    }
  end
end

def match_service_url(endpoints, url_pattern)
  endpoints.select do |catalog_entry|
    catalog_entry['endpoints'].any? { |endpoint|
      is_url = false
      is_url = true if endpoint['publicURL'] =~ url_pattern
      is_url = true if endpoint['interface'] == 'public' && endpoint['url'] =~ url_pattern
      is_url
    }
  end
end

def scrub_random_body_value!(request, key)
  request[:body].gsub!(/"#{key}":\".*?\"/, "\"#{key}\":\"<#{key}>\"")
end

def scrub_random_body_hash!(request, key)
  request[:body].gsub!(/"#{key}":\{[^{]*?\}/, "\"#{key}\":\"<#{key}>\"")
end

def scrub_random_query_value!(query, key)
  query.gsub!(/(\A|&|=|")#{key}=.*?(\Z|&|")/, "\\1#{key}=<#{key}>\\2")
end

def scrub_random_query_has_value!(query, key)
  query.gsub!(/"#{key}"=>".*?"/, "\"#{key}\":\"<#{key}>\"")
end

def scrub_random_values!(requests)
  requests.each do |request|
    tenant_id_regex = /[a-fA-F0-9]{32}/
    tenant_id_alternative_regex = /p-[a-fA-F0-9]{9}/
    resource_id_regex = /[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}/

    request[:path].gsub!(tenant_id_regex, '<tenant_id>')
    request[:path].gsub!(tenant_id_alternative_regex, '<tenant_id>')
    request[:path].gsub!(resource_id_regex, '<resource_id>')
    # life cycle test uses this fake ids which doesn't match any uuid reqex
    request[:path].gsub!('non-existing-disk', '<resource_id>')
    request[:path].gsub!('non-existing-vm-id', '<resource_id>')
    keys_to_scrub = [
        'user_data', 'display_description', 'device', 'password', 'fixed_ip', 'availability_zone', 'key_name', 'username',
        'tenantName', 'name', 'token', 'ip_address', 'device_id', 'version', 'floating_ip_address', 'network_id', 'description',
        'metadata', 'address'
    ]
    if request[:query]
      keys_to_scrub.each do |key|
        scrub_random_query_value!(request[:query], key)
        scrub_random_query_has_value!(request[:query], key)
      end
    end
    if request[:body]
      request[:body].gsub!(resource_id_regex, '<resource_id>')
      request[:body].gsub!(/"new_size":\d+/, "\"new_size\":\"<new_size>\"")
      request[:body].gsub!(/"volume_size":\d+/, "\"volume_size\":\"<volume_size>\"")
      request[:body].gsub!(/"flavorRef":"\d+"/, "\"flavorRef\":\"<flavorRef_id>\"")
      request[:body].gsub!(/"size":\d+/, "\"size\":\"<size>\"")
      request[:body].gsub!(/"protocol_port":\d+/, "\"protocol_port\":\"<protocol_port>\"")
      keys_to_scrub.each do |key|
        scrub_random_body_value!(request, key)
        scrub_random_body_hash!(request, key)
      end
    end
  end
end

def unescape_double_quote(string)
  string.gsub('\"', '"') if string
end

def update_catalog_endpoints(line)
  body_regex = /body: ({.*})/
  body = JSON.parse(unescape_double_quote(body_regex.match(line)[1]))
  body.dig("token", "catalog") || body.dig("access", "serviceCatalog")
end

def run
  requests = []
  endpoints = nil
  STDIN.each_line do |line|
    endpoints ||= update_catalog_endpoints(line) if line =~ /excon\.response .*?(catalog|serviceCatalog)/

    request_regex = /^.*excon\.request (.*)$/
    matched = request_regex.match(line)
    if matched
      host_regex = /"host":"([^"]*)"/
      query_regex = /"query":({.*?})(,)/
      body_regex = /body: ({.*})/

      log_regex = /^(?<method>\w+) .*?:\/\/.*?:(?<port>\d+)(?<path>.*?) params:/
      log_matched = log_regex.match(matched[1])

      request = {
        method: log_matched[:method],
        port: log_matched[:port],
        path: log_matched[:path],
        host: host_regex.match(matched[1])[1],
      }
      query = query_regex.match(matched[1])
      request[:query] = json_to_query_string(query[1]) if query
      body = body_regex.match(matched[1])
      request[:body] = unescape_double_quote(body[1]) if body

      requests << request
    end
  end

  unless endpoints
    raise 'No catalog with endpoints found'
  end

  scrub_random_values!(requests)
  requests.uniq!
  requests.each do |request|
    request[:target] = target_service(request, endpoints)
  end

  lines = endpoints.sort_by { |entry| entry['type'] }
    .reduce([]) do |result, catalog_entry|
    result << ["### All calls for API endpoint '#{catalog_entry['type']} (#{catalog_entry['name']})'"]
    requests_per_catalog_entry = requests.select(&request_of(catalog_entry['type'])).map(&to_formatted_line).sort

    result.push(*['```', requests_per_catalog_entry, '```']) unless requests_per_catalog_entry.empty?

    result
  end
  lines.each { |line| puts line }
end

def request_of(catalog_entry_type)
  lambda { |request| request[:target][:type] == catalog_entry_type }
end

def json_to_query_string(query_hash_string)
  if query_hash_string != '{}'
    parsed_query = JSON.parse(unescape_double_quote(query_hash_string))
    parsed_query.keys.map { |key| "#{key}=#{parsed_query[key]}" }.join('&')
  end
end

def to_formatted_line
  lambda { | request|
    query = ''
    if request[:query]
      query = "?#{request[:query]}"
    end
    body = ''
    if request[:body]
      body = " body: #{unescape_double_quote(request[:body])}"
    end
    "#{request[:method]} #{request[:path]}#{query}#{body}"
  }
end