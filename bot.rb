require 'facebook/messenger'
require 'httparty'
require 'haversine'
require 'json'
require "unidecoder"
include Facebook::Messenger

Facebook::Messenger::Subscriptions.subscribe(access_token: ENV["ACCESS_TOKEN"])

# BOT WORDINGS
TEXT = {
  greeting: "Hello {{user_first_name}} 👋 Moi c\'est Captain Metro 🤖 Je suis là pour te donner les prochains passages du métro de ton choix 🚊 GO !",
  menu_schedules: 'HORAIRES 🕘',
  menu_trafic: 'INFOS TRAFIC ⚠',
  ask_location: "Tu peux entrer un lieu à la main 🤘 Ou me partager ta localisation 📍",
  ask_stop: "Voici les 3 stations les plus proches de toi. Laquelle t'intéresse ? 🚊",
  not_found: "Arf, essaye d'ajouter \"Paris\" après ta requête cela devrait m'aider 🙌",
  unknown_command: "Désolé, je suis pas très intelligent 😬 Ce que t'écris, je l'envoie directement à Google pour savoir où tu es. Tu peux donc me partager un lieu ou ta localisation 🚩",
}.freeze

# RATP DB
ratp_json = File.read('ratp.json')
@ratp = JSON.parse(ratp_json)

# # Greetings first contact
Facebook::Messenger::Profile.set({
  greeting: [
    {
      locale: 'default',
      text: TEXT[:greeting]
    }
  ]
}, access_token: ENV['ACCESS_TOKEN'])

# # Get Started CTA
Facebook::Messenger::Profile.set({
  get_started: {
    payload: 'START'
  }
}, access_token: ENV['ACCESS_TOKEN'])

# # Create persistent menu
Facebook::Messenger::Profile.set({
  persistent_menu: [
    {
      locale: 'default',
      composer_input_disabled: false,
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
            elements: @ratp_trafic_results[0...9]
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
      ratp_closest_stops(location)
      message.reply(
        attachment: {
          type: 'template',
          payload: {
            template_type: 'button',
            text: TEXT[:ask_stop],
            buttons: @stops_shortlist
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
      p parsed_google_response
      location = parsed_google_response['results'].first['geometry']['location']
      if Haversine.distance([location['lat'],location['lng']],[48.8587741,2.2074741]).to_km < 60
        ratp_closest_stops([location['lat'],location['lng']])
        message.reply(
          attachment: {
            type: 'template',
            payload: {
              template_type: 'button',
              text: TEXT[:ask_stop],
              buttons: @stops_shortlist
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
  end
end

# Geocoding API
def google_locate_user(query)
  google_url = 'https://maps.googleapis.com/maps/api/geocode/json?address='
  google_response = HTTParty.get(google_url + query + ENV["GOOGLE_API_TOKEN"])
  parsed_google_response = JSON.parse(google_response.body)
end

# Closest stops based on user location
def ratp_closest_stops(location)
  stops_by_distance = []
  @ratp['ratp_json'].each do |stop|
    distance = Haversine.distance(location,stop['coord']).to_m
    stops_by_distance << [stop['slug'], stop['name'], distance]
  end
  raw_shortlist = stops_by_distance.sort{|a,b| a[2] <=> b[2]}[0...3]
  @stops_shortlist = []
  raw_shortlist.each do |stop|
    @stops_shortlist << { type: 'postback', title: stop[1], payload: "#{stop[0]}" }
  end
end

# RATP API for schedules
def ratp_schedules(stop_id)
  @ratp_schedules_results = []
  stop_selected = @ratp['ratp_json'].select {|stop| stop['slug'] == stop_id}.first
  stop_selected['lines'].each do |line|
    ["A", "R"].each do |destination|
      ratp_schedules_api = "https://api-ratp.pierre-grimaud.fr/v3/schedules/#{line['type']}/#{line['line']}/#{stop_id}/#{destination}"
      ratp_schedules_response = HTTParty.get(ratp_schedules_api)
      parsed_ratp_schedules_response = JSON.parse(ratp_schedules_response.body)
      if parsed_ratp_schedules_response['result']['schedules']
        ratp_schedules_destination = parsed_ratp_schedules_response['result']['schedules'][0]['destination']
        ratp_schedules_type = line['type']
        ratp_schedules_line = line['line']
        ratp_schedules_stop = stop_selected['name']
        ratp_schedules_next = parsed_ratp_schedules_response['result']['schedules']
        ratp_schedules_array = []
        ratp_schedules_next.each do |schedule|
          ratp_schedules_array << "#{schedule['message']}"
        end
        ratp_schedules_subtitle = ratp_schedules_array.join("\r\n")
        @ratp_schedules_results << { title: ratp_schedules_destination, image_url: "https://raw.githubusercontent.com/gregcha/hellometro/master/images/#{line['line']}.png", subtitle: "#{ratp_schedules_subtitle}", buttons:[ {type: "postback", title: "Actualiser", payload: stop_id}, {type: "postback", title: "Nouvelle Recherche", payload: "START"}]}
      else
        @ratp_schedules_results << { title: "Ooooops 😥", image_url: "https://raw.githubusercontent.com/gregcha/hellometro/master/images/#{line['line']}.png", subtitle: "Le Captain te présente ses plus plates excuses pour cette erreur 🙏"}
      end
    end
  end
end

# RATP API for trafic
def ratp_trafic
  @ratp_trafic_results = []
  ["metros", "rers"].each do |type|
    ratp_trafic_api = "https://api-ratp.pierre-grimaud.fr/v3/traffic/#{type}"
    ratp_trafic_response = HTTParty.get(ratp_trafic_api)
    parsed_ratp_trafic_response = JSON.parse(ratp_trafic_response.body)
    ratp_trafic_array = []
    parsed_ratp_trafic_response['result']["#{type}"].each do |line_trafic_status|
      if line_trafic_status['slug'] != 'normal'
        ratp_trafic_subtitle = "#{line_trafic_status['message']}"
        @ratp_trafic_results << { title: line_trafic_status['title'], image_url: "https://raw.githubusercontent.com/gregcha/hellometro/master/images/#{line_trafic_status['line']}.png", subtitle: ratp_trafic_subtitle}
      end
    end
  end
  @ratp_trafic_results << { title: "Trafic normal", image_url: "https://raw.githubusercontent.com/gregcha/hellometro/master/images/ratp.png", subtitle: "Trafic normal sur l'ensemble des autres lignes"}
end


