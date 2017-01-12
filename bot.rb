require 'facebook/messenger'
require 'httparty'
require 'haversine'
require 'json'
require "unidecoder"
include Facebook::Messenger

Facebook::Messenger::Subscriptions.subscribe(access_token: ENV["ACCESS_TOKEN"])

# BOT WORDINGS
TEXT = {
  greeting: 'Hello {{user_first_name}} 👋 ! Moi c\'est Pierrot du Métro. Mon but ? Te donner les prochains passages du métro de ton choix 🚊. Aller go !',
  menu_schedules: 'HORAIRES 🚊',
  menu_trafic: 'INFOS TRAFIC ⚠',
  ask_location: "Tu peux entrer un lieu à la main ou me partager ta localisation (y)",
  ask_station: "Voici les 3 stations les plus proches de toi. Laquelle t'intéresse ? 🚊",
  not_found: "Désolé, je ne connais pas ce lieu :'( Peux-tu préciser ou me partager ta localisation ? 🙏",
  unknown_command: "Ooops... ça je ne sais pas faire :) Tu peux entrer un lieu ou me partager ta location (y)",
}.freeze

# RATP DB
ratp_json = File.read('ratp.json')
@ratp = JSON.parse(ratp_json)

# Greetings first contact
Facebook::Messenger::Thread.set({
  setting_type: 'greeting',
  greeting: {
    text: TEXT[:greeting]
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
      title: TEXT[:menu_schedules],
      payload: 'START'
    },
    {
      type: 'postback',
      title: TEXT[:menu_trafic],
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
        text: TEXT[:ask_location],
        quick_replies: [
          {
            content_type: 'location',
          }
        ]
      },
    }, access_token: ENV['ACCESS_TOKEN'])
  when 'RATP_STATUS'
    ratp_trafic
    Bot.deliver({
      recipient: {
        id: sender_id
      },
      message: {
        attachment: {
          type: "template",
          payload: {
            template_type: "generic",
            elements: @ratp_trafic_results
          }
        }
      }
    }, access_token: ENV['ACCESS_TOKEN'])
  else
    ratp_schedules(postback.payload)
    Bot.deliver({
      recipient: {
        id: sender_id
      },
      message: {
        attachment: {
          type: "template",
          payload: {
            template_type: "generic",
            elements: @ratp_schedules_results
          }
        }
      }
    }, access_token: ENV['ACCESS_TOKEN'])
  end
end

# Logic for message and shared location
Bot.on :message do |message|
  puts message.inspect
  if message.attachments
    if message.attachments[0]['type'] == 'location'
      location = [message.attachments[0]['payload']['coordinates']['lat'], message.attachments[0]['payload']['coordinates']['long']]
      ratp_closest_stations(location)
      message.reply(
        attachment: {
          type: 'template',
          payload: {
            template_type: 'button',
            text: TEXT[:ask_station],
            buttons: @stations_shortlist
          }
        }
      )
    else
      message.reply({
        text: TEXT[:unknown_command],
        quick_replies: [
          {
            content_type: 'location',
          }
        ]
      })
    end
  else
    query = message.text.to_ascii
    parsed_google_response = google_locate_user(query)
    if parsed_google_response['status'] == 'OK'
      location = parsed_google_response['results'].first['geometry']['location']
      ratp_closest_stations([location['lat'],location['lng']])
      message.reply(
        attachment: {
          type: 'template',
          payload: {
            template_type: 'button',
            text: TEXT[:ask_station],
            buttons: @stations_shortlist
          }
        }
      )
    else
      message.reply({
        text: TEXT[:not_found],
        quick_replies: [
          {
            content_type: 'location',
          }
        ]
      })
    end
  end
end

# Geocoding API
def google_locate_user(query)
  google_url = 'https://maps.googleapis.com/maps/api/geocode/json?address='
  google_response = HTTParty.get(google_url + query)
  parsed_google_response = JSON.parse(google_response.body)
end

# Closest stations based on user location
def ratp_closest_stations(location)
  stops_by_distance = []
  @ratp['ratp_json'].each do |stop|
    distance = Haversine.distance(location,stop['coord']).to_m
    stops_by_distance << [stop['id'], stop['name'], distance]
  end
  raw_shortlist = stops_by_distance.sort{|a,b| a[2] <=> b[2]}[0...3]
  @stations_shortlist = []
  raw_shortlist.each do |stop|
    @stations_shortlist << { type: 'postback', title: stop[1], payload: "#{stop[0]}" }
  end
end

# RATP API for schedules
def ratp_schedules(stop_id)
  @ratp_schedules_results = []
  stop_selected = @ratp['ratp_json'].select {|stop| stop['id'] == stop_id}.first
  stop_selected['stations'].each do |station|
    station['destinations'].each do |destination|
      ratp_schedules_api = "https://api-ratp.pierre-grimaud.fr/v2/#{stop_selected['type']}/#{station['line']}/stations/#{stop_selected['id']}?destination=#{destination['id']}"
      ratp_schedules_response = HTTParty.get(ratp_schedules_api)
      parsed_ratp_schedules_response = JSON.parse(ratp_schedules_response.body)
      parsed_ratp_schedules_response['response']['code'] != '404' ? parsed_ratp_schedules_response : nil
      if parsed_ratp_schedules_response
        ratp_schedules_type = parsed_ratp_schedules_response['response']['informations']['type']
        ratp_schedules_line = parsed_ratp_schedules_response['response']['informations']['line']
        ratp_schedules_station = parsed_ratp_schedules_response['response']['informations']['station']['name']
        ratp_schedules_next = parsed_ratp_schedules_response['response']['schedules']
        ratp_schedules_array = []
        ratp_schedules_next.each do |schedule|
          if destination['id'] == "18" || destination['id'] == "32"
            ratp_schedules_array << "- #{schedule['message']} - #{schedule['destination'].gsub(/['-]/, " ").split.map(&:chr).join}"
          else
            ratp_schedules_array << "- #{schedule['message']}"
          end
        end
        ratp_schedules_subtitle = ratp_schedules_array.join("\r\n")
        @ratp_schedules_results << { title: destination['name'], image_url: station['image_url'], subtitle: "#{ratp_schedules_subtitle}", buttons:[ {type: "postback", title: "Actualiser", payload: stop_id}]}
      else
        ratp_schedules_subtitle = "Houston on a un problème sur cette ligne : #{stop_selected['type'].upcase} N°#{station['line']} - #{stop_selected['name']} vers #{destination['name']}. Je suis désolé :("
        @ratp_schedules_results << { title: destination['name'], image_url: station['image_url'], subtitle: ratp_schedules_subtitle}
      end
    end
  end
end

# RATP API for trafic
def ratp_trafic
  @ratp_trafic_results = []
  ratp_trafic_api = "https://api-ratp.pierre-grimaud.fr/v2/traffic/metros"
  ratp_trafic_response = HTTParty.get(ratp_trafic_api)
  parsed_ratp_trafic_response = JSON.parse(ratp_trafic_response.body)
  ratp_trafic_array = []
  parsed_ratp_trafic_response['response']['metros'].each do |line_trafic_status|
    if line_trafic_status['slug'] != 'normal'
      ratp_trafic_subtitle = "#{line_trafic_status['message']}"
      @ratp_trafic_results << { title: line_trafic_status['title'], image_url: "https://raw.githubusercontent.com/gregcha/hellometro/master/images/#{line_trafic_status['line']}.png", subtitle: ratp_trafic_subtitle}
    end
  end
  @ratp_trafic_results << { title: "Trafic normal", image_url: "https://raw.githubusercontent.com/gregcha/hellometro/master/images/metro.png", subtitle: "Trafic normal sur l'ensemble des autres lignes"}
end


