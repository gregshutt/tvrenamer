require 'optparse'
require 'sequel'

options = {}
opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: tvrenamer-fetch-series.rb [options]"

	opts.on "-sSHOW", "--show=SHOW", "Name of the show to download" do |show|
		options[:movie_name] = show
	end

	opts.on "-eSEASON", "--season=SEASON", "Which season to download" do |season|
		options[:series_season] = season
	end

	opts.on "-h", "--help", "Prints this help" do
		puts opts
		exit
	end
end
opt_parser.parse!

if options[:movie_name].nil?
	puts "Show name is required"
	exit 1
end

def main(options = {})
	db = Sequel.connect('sqlite://opensubtitles.db')

	# get all the seasons and episodes
	query = db[:titles].filter(movie_name: options[:movie_name], language_code: 'en', movie_kind: 'tv', subtitle_format: 'srt')

	# limit to the selected season
	if ! options[:series_season].nil?
		query = query.filter(series_season: options[:series_season])
	end
	
	# order by descending date to get the newest subtitles
	query = query.order(:date)

	# get a list of unique seasons and episodes
	episodes = query.all.uniq { |q| q.values_at(:series_season, :series_episode) }
	
	episodes.sort! { |t1, t2| [t1[:series_season].to_i, t1[:series_episode].to_i] <=> [t2[:series_season].to_i, t2[:series_episode].to_i] }
	
	download_index = 0
	episodes.each do |t|
		if (download_index > 0) && (download_index % 30 == 0)
			# pause after 30 episodes
			sleep 4000
		end

		season = "%02d" % t[:series_season].to_i
		episode = "%02d" % t[:series_episode].to_i
		print "Getting S#{season}E#{episode}..."
		puts t[:url]

		# check if the subtitle exists
		filename = "#{options[:movie_name]} - S#{season}E#{episode}.srt"
		if File.exist? filename
			puts "already downloaded."
			next
		end

		system("ruby tvrenamer-download.rb -s #{t[:os_id]} -o '#{filename}'")
		puts "done."

		download_index += 1
	end
end

main(options)
