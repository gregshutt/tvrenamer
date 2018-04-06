# http://dl.opensubtitles.org/addons/export/subtitles_all.txt.gz

require 'csv'
require 'sequel'

FIELD_COUNT = [ 16, 17 ]

def main
	db = Sequel.connect('sqlite://opensubtitles.db')

	db.create_table :titles do
		primary_key :id
		Integer :os_id
		String :movie_name
		Integer :movie_year
		String :movie_kind
		String :language_code
		String :series_season
		String :series_episode
		String :subtitle_format
		Date :date
		String :url
	end

	titles = db[:titles]
	batch = []

	IO.foreach('subtitles_all.txt').with_index do |line, line_no|
		# skip the first line
		next if line_no == 0

		# split on tab
		fields = line.split("\t")
		
		if ! FIELD_COUNT.include? fields.count
			puts "Warning: line #{line_no}: expected #{FIELD_COUNT.join(' or ')} fields, got #{fields.count}"
			next
		end

		movie_name = fields[1].strip
		movie_kind = fields[14].strip.downcase

		case movie_kind
		when 'tv'
			# split into episode/series names
			movie_name = movie_name.scan(/"([^"]*)"/)[0]
		end

		batch << {
			os_id: fields[0], 
			movie_name: movie_name, 
			movie_year: fields[2], 
			language_code: fields[4], 
			subtitle_format: fields[7], 
			series_season: fields[11],
			series_episode: fields[12], 
			movie_kind: fields[14], 
			date: fields[5],
			url: fields[15]
		}

		if batch.size >= 1000
			insert_batch(db, titles, batch)
			batch = []
		end
	end

	# add the remaining items
	insert_batch(db, titles, batch)
end

def insert_batch(database, table, batch)
	begin
		database.transaction do
			batch.each do |b|
				table.insert b
			end
		end
	rescue Exception => e
		raise
	end
end

main
