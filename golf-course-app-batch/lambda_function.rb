require 'google_maps_service'
require 'rakuten_web_service'
require 'aws-record'

class SearchGolfApp # DynamoDBのテーブル名とします
  include Aws::Record
  integer_attr :golf_course_id, hash_key: true
  integer_attr :duration1 # 基準地点1からの所要時間
  integer_attr :duration2 # 基準地点2からの所要時間
end

module Area
  # 楽天APIで定められているエリアコード（8:茨城県,11:埼玉県,12:千葉県,13:東京都,14:神奈川県）
  # この5つのエリアを対象とします
  # 参考(楽天APIの仕様):https://webservice.rakuten.co.jp/api/areacode/golfarea.html
  CODES = ['8', '11', '12', '13', '14']
end

module Departure
  # 基準とする出発地点(今回はこの2箇所を基準となる出発地点とします)
  DEPARTURES = {
   1 => '東京駅',
   2 => '横浜駅',
  }
end

def duration_minutes(departure, destination)
  # Google Maps Platformを使って出発地点とゴルフ場の車での移動時間を出しています
  gmaps = GoogleMapsService::Client.new(key: ENV['GOOGLE_MAP_API_KEY'])
  routes = gmaps.directions(
    departure,
    destination,
    region: 'jp'
  )
  return unless routes.first # ルートが存在しないときはnilを返す(東京の離島など)
  duration_seconds = routes.first[:legs][0][:duration][:value] # レスポンスから所要時間(秒)を取得しています
  duration_seconds / 60 # 単位が「秒」なので「分」に直しています
end

def put_item(course_id, durations) # DynamoDBへ保存します
    begin
        return if SearchGolfApp.find(golf_course_id: course_id) # 既にDynamoDBに同じコースIDのレコードが存在した場合は新たに保存しない
      rescue => e
        e
    end
    
  duration = SearchGolfApp.new
  duration.golf_course_id = course_id
  duration.duration1 = durations.fetch(1)
  duration.duration2 = durations.fetch(2)
  duration.save
end

def lambda_handler(event:, context:) # バッチ処理が起動したときに最初に動くメソッド
  RakutenWebService.configure do |c|
    c.application_id = ENV['RAKUTEN_APPID']
    c.affiliate_id = ENV['RAKUTEN_AFID']
  end

  Area::CODES.each do |code| # 全てのエリアに対して以下操作を行う
    1.upto(100) do |page| # 楽天APIで取得できる全てのゴルフ場に対して以下操作を行う
      # コース一覧を取得する(楽天APIの仕様上、一度に全てのゴルフ場を取得できないのでpageを分けて取得している) 参考(楽天APIの仕様):https://webservice.rakuten.co.jp/api/goragolfcoursesearch/
     courses = RakutenWebService::Gora::Course.search(areaCode: code, page: page)
      courses.each do |course|
        course_id = course['golfCourseId']
        course_name = course['golfCourseName']
        next if course_name.include?('レッスン') # ゴルフ場以外の情報(レッスン情報)をこれでスキップしてる

        durations = {}
        Departure::DEPARTURES.each do |duration_id, departure|
          minutes = duration_minutes(departure, course_name)
          durations.store(duration_id, minutes) if minutes
        end
        put_item(course_id, durations) unless durations.empty? # コースIDとそれぞれの出発地点とコースへの移動時間をDynamoDBへ格納する
      end
      break unless courses.next_page? # 次のページが存在するかどうか確認するメソッド
    end
  end

  { statusCode: 200 }
end
