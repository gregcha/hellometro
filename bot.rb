require 'facebook/messenger'
require 'httparty'
require 'haversine'
require 'json'
require "unidecoder"
include Facebook::Messenger

Facebook::Messenger::Subscriptions.subscribe(access_token: ENV["ACCESS_TOKEN"])

# RATP DB
ratp_json = File.read('ratp.json')
@ratp = JSON.parse(ratp_json)

# Greetings first contact
Facebook::Messenger::Thread.set({
  setting_type: 'greeting',
  greeting: {
    text: 'Hello {{user_first_name}}, bienvenue sur Hello Metro !'
  },
}, access_token: ENV['ACCESS_TOKEN'])

# Get Started CTA
Facebook::Messenger::Thread.set({
  setting_type: 'call_to_actions',
  thread_state: 'new_thread',
  call_to_actions: [
    {
      payload: 'START'
    }
  ]
}, access_token: ENV['ACCESS_TOKEN'])

# Create persistent menu
Facebook::Messenger::Thread.set({
  setting_type: 'call_to_actions',
  thread_state: 'existing_thread',
  call_to_actions: [
    {
      type: 'postback',
      title: 'Prochains Metros',
      payload: 'START'
    },
    {
      type: 'postback',
      title: 'Infos Trafic',
      payload: 'RATP_STATUS'
    }
  ]
}, access_token: ENV['ACCESS_TOKEN'])

# Logic for postbacks
Bot.on :postback do |postback|
  puts postback.inspect
  sender_id = postback.sender['id']

  case postback.payload
  when 'START'
    Bot.deliver({
      recipient: {
        id: sender_id
      },
      message: {
        text: "Entrez un lieu ou partagez votre location",
        quick_replies: [
          {
            content_type: 'location',
          }
          # ,
          # { to do
          #   content_type: "text",
          #   title: "Infos Trafic",
          #   payload: "RATP_STATUS"
          # }
        ]
      },
    }, access_token: ENV['ACCESS_TOKEN'])
  when 'RATP_STATUS'
    # to do : https://api-ratp.pierre-grimaud.fr/v2/traffic/metros
  else
    ratp_schedules(postback.payload)

    # @messages.each do |message|
      Bot.deliver({
        recipient: {
          id: sender_id
        },
        message: {
          attachment: {
            type: "template",
            payload: {
              template_type: "generic",
              elements: @messages
            }
          }
        }
        # message: {
        #   text: message
        # },
      }, access_token: ENV['ACCESS_TOKEN'])
    # end
  end
end

# Logic for message and shared location
Bot.on :message do |message|
  puts message.inspect
  if message.text.nil?
    location = [message.attachments[0]['payload']['coordinates']['lat'], message.attachments[0]['payload']['coordinates']['long']]
    ratp_closest_stations(location)
    # message.reply({
    #   text: "Pick a color:",
    #   quick_replies: @shortlist
    # }
    message.reply(
      attachment: {
        type: 'template',
        payload: {
          template_type: 'button',
          text: 'Choisir l\'arrêt souhaité',
          buttons: @shortlist
        }
      }
    )
  else
    query = message.text.to_ascii
    parsed_google_response = google_locate_user(query)
    if parsed_google_response
      location = parsed_google_response['results'].first['geometry']['location']
      ratp_closest_stations([location['lat'],location['lng']])
      # message.reply({
      #   text: "Pick a color:",
      #   quick_replies: @shortlist
      # }
      message.reply(
        attachment: {
          type: 'template',
          payload: {
            template_type: 'button',
            text: 'Choisir l\'arrêt souhaité',
            buttons: @shortlist
          }
        }
      )
    else
      message.reply(text: 'Désolé mais je ne connais pas cet endroit...')
    end
  end
end

# Geocoding API
def google_locate_user(query)
  google_url = 'https://maps.googleapis.com/maps/api/geocode/json?address='
  google_response = HTTParty.get(google_url + query)
  parsed_google_response = JSON.parse(google_response.body)
  parsed_google_response['status'] != 'ZERO_RESULTS' ? parsed_google_response : nil
end

# Closest stations based on user location
def ratp_closest_stations(location)
  stops_by_distance = []
  @ratp['ratp_json'].each do |stop|
    distance = Haversine.distance(location,stop['coord']).to_m
    stops_by_distance << [stop['id'], stop['name'], distance]
    # stop['stations'].each do |station|
    #   stops_by_distance << [stop['id'], stop['name'], station['image_url'], distance]
    # end
  end
  raw_shortlist = stops_by_distance.sort{|a,b| a[2] <=> b[2]}[0...3]
  @shortlist = []
  raw_shortlist.each do |stop|
    # @shortlist << { content_type: 'text', title: stop[1], payload: "#{stop[0]}", image_url: "#{stop[2]}" }
    @shortlist << { type: 'postback', title: stop[1], payload: "#{stop[0]}" }
  end
end

# RATP API for schedules
def ratp_schedules(stop_id)
  @messages = []
  stop_selected = @ratp['ratp_json'].select {|stop| stop['id'] == stop_id}.first
  stop_selected['stations'].each do |station|
    station['destinations'].each do |destination|
      ratp_schedules_api_query = "https://api-ratp.pierre-grimaud.fr/v2/#{stop_selected['type']}/#{station['line']}/stations/#{stop_selected['id']}?destination=#{destination['id']}"
      ratp_schedules_response = HTTParty.get(ratp_schedules_api_query)
      parsed_ratp_schedules_response = JSON.parse(ratp_schedules_response.body)
      parsed_ratp_schedules_response['response']['code'] != '404' ? parsed_ratp_schedules_response : nil
      if parsed_ratp_schedules_response
        ratp_schedules_type = parsed_ratp_schedules_response['response']['informations']['type']
        ratp_schedules_line = parsed_ratp_schedules_response['response']['informations']['line']
        ratp_schedules_station = parsed_ratp_schedules_response['response']['informations']['station']['name']
        ratp_schedules_next = parsed_ratp_schedules_response['response']['schedules']
        ratp_schedules_array = []
        ratp_schedules_next.each do |schedule|
          ratp_schedules_array << "#{schedule['message']}" #vers #{schedule['destination']}"
        end
        ratp_schedules_string = ratp_schedules_array.join("\r\n- ")
        # @messages << "#{ratp_schedules_type.upcase} N°#{ratp_schedules_line} - #{ratp_schedules_station}\r\n- #{ratp_schedules_string}"
        @messages << { title: destination['name'], image_url: "https://raw.githubusercontent.com/gregcha/portfolio/master/source/images/me/me.png", subtitle: "- #{ratp_schedules_string}" }
      else
        @messages << "Houston on a un problème sur cette ligne : #{stop_selected['type'].upcase} N°#{station['line']} - #{stop_selected['name']} vers #{destination['name']}. Je suis désolé :("
      end
    end
  end
end


