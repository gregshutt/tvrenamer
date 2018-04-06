require 'winnow'
require 'optparse'
require 'srt'
require 'tempfile'

options = {}
options[:external_decoder_host] = nil
options[:pretend] = false
options[:show] = nil
options[:subtitle_path] = './subtitles'
options[:videos] = []

opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: tvrenamer-rename.rb [options] [videos]"

	opts.on "-dHOST", "--external-decoder=HOST", "Sets the hostname of the external SUP decoder" do |s|
		options[:external_decoder_host] = s
	end

    opts.on "-h", "--help", "Prints this help" do
        puts opts
        exit
    end

	opts.on "-p", "--pretend", "Don't actually perform renaming" do
		options[:pretend] = true
	end

	opts.on "-sSHOW", "--show=SHOW", "Limits the show that will be searched" do |s|
		options[:show] = s
	end

	opts.on "-eSEASON", "--season=SEASON", "Limits the season that will be searched" do |s|
		options[:season] = s
	end

	opts.on "-tPATH", "--subtitle-path=PATH", "Select the path where subtitles are stored" do |s|
		options[:subtitle_path] = s
	end
end
opt_parser.parse!

# assume the remaining options are videos
options[:videos] = ARGV.dup

if options[:videos].empty?
	puts "Need at least one video file to identify\n\n"
	puts opt_parser
	exit
end

def main(options)
	subtitles = {}

	# load all the srt files
	print "Loading SRT files..."
	Dir.foreach(options[:subtitle_path]) do |item|
		next if item == '.' || item == '..'

		if ! options[:show].nil?
			# skip files not related to this show
			next if ! item.start_with? options[:show]
		end

		if ! options[:season].nil?
			# skip files outside of the season
			next if item !~ /S\d?#{options[:season]}E/
		end

		srt = SRT::File.parse(File.new("#{options[:subtitle_path]}/#{item}"))

		subtitles[item] = extract_srt_text(srt)
	end
	puts "done."

	puts "Loaded #{subtitles.count} subtitles"

	if subtitles.count == 0
		raise "Could not load any subtitles"
	end

	# go through each mkv file
	options[:videos].each do |v|
		video_basename = File.basename(v)
		puts "Looking at #{video_basename}..."
		
		# use mkvinfo to get the subtitle tracks
		mkvinfo = `mkvinfo-text '#{v}'`
		subtitle_tracks = parse_mkvinfo(mkvinfo)

		if subtitle_tracks.empty?
			raise "Could not find subtitle tracks for #{v}"
		end

		puts "  Found #{subtitle_tracks.count} subtitle track#{subtitle_tracks.count == 1 ? '' : 's'}"

		# use mkvextract to extract the .sub/.idx files
		subtitle_tracks.each do |track_id, track_info|
			print "  Extracting track ID #{track_id}..."
			track_file = Tempfile.new('track')
			begin
				`mkvextract tracks '#{v}' #{track_id}:#{track_file.path}`
				puts "done."

				print "    Converting to text..."

				case track_info[:codec]
				when 'S_VOBSUB'
					# use vobsub2srt to convert to srt
					`vobsub2srt #{track_file.path} 2>&1`
					
					srt = SRT::File.parse(File.new("#{track_file.path}.srt"))
					full_text = extract_srt_text(srt)

				when 'S_HDMV/PGS'
					raise "External decoder host not set" if options[:external_decoder_host].nil?

					# pass off to external decoder
					external_file = `ssh #{options[:external_decoder_host]} "mktemp"`.chomp

					# copy the file in
					`scp #{track_file.path} #{options[:external_decoder_host]}:c\:/cygwin64/#{external_file}`

					# use subtitleedit to convert
					`ssh #{options[:external_decoder_host]} "Downloads/SE351/SubtitleEdit.exe /convert c\:/cygwin64/#{external_file} SubRip"`

					# figure out where subtitleedit put the file
					external_srt_file = "#{File.dirname(external_file)}/#{File.basename(external_file, '.*')}.srt"

					temp_srt_file = Tempfile.new('srt')
					`scp #{options[:external_decoder_host]}:c\:/cygwin64/#{external_srt_file} #{temp_srt_file.path}`

					`ssh #{options[:external_decoder_host]} "rm '#{external_srt_file}'"`
					`ssh #{options[:external_decoder_host]} "rm '#{external_file}'"`
					
					srt = SRT::File.parse(File.new(temp_srt_file.path))
					full_text = extract_srt_text(srt)

				else
					raise "Unknown subtitle format: #{track_info[:codec]}"
				end
			ensure
				track_file.close
				track_file.unlink
			end

			puts "done."

			print "    Searching for best match..."
			
			best_srt_file = find_best_match(subtitles, full_text)

			puts "done."

			if ! best_srt_file.nil?
				# rename the file
				srt_basename = File.basename(best_srt_file)
				srt_extension = File.extname(best_srt_file)
				srt_filename = File.basename(best_srt_file, srt_extension)
				
				video_extension = File.extname(video_basename)

				print "    Renaming #{video_basename} to #{srt_filename}#{video_extension}..."

				video_dir = File.dirname(v)
				new_video_path = "#{video_dir}/#{srt_filename}#{video_extension}"

				if File.exists? new_video_path
					raise "Found existing filename #{new_video_path}"
				end

				if ! options[:pretend]
					File.rename("#{v}", "#{new_video_path}") 
				end

				puts "done."

				# continue to next video
				break
			end
		end

	end
	exit
end

def extract_srt_text(srt)
	srt.lines.map { |line| line.text.join(' ') }.join(' ')
end

def parse_mkvinfo(mkvinfo)
	subtitle_tracks = {}

	in_track = false
	in_subtitle = false
	track = {}

	mkvinfo.lines.map(&:chomp).each do |line|
		if line.start_with? '| + A track'
			in_track = true

			# add the previous track if valid
			if track[:type] == 'Subtitle' && track[:language] == 'English'
				subtitle_tracks[track[:number]] = track
			end
	
			# reset
			track = {}
		end

		if line.start_with?('|  + Track number: ')
			# parse out the track id
			track_match = /mkvextract: (\d+)\)/.match(line)
			track[:number] = track_match[1]
		end

		if line.start_with?('|  + Track type: subtitles')
			track[:type] = 'Subtitle'
		end

		if line.start_with?('|  + Language: eng')
			track[:language] = 'English'
		end

		# store the codec
		if line.start_with?('|  + Codec ID: ')
			track[:codec] = line.match(/Codec ID: (.+)\z/).captures[0]
		end
	end

	# add the existing track if valid
	if track[:type] == 'Subtitle' && track[:language] == 'English'
		subtitle_tracks[track[:number]] = track
	end

	subtitle_tracks
end
	
def find_best_match(subtitles, full_text)
	full_text = full_text.downcase

	fp = Winnow::Fingerprinter.new(guarantee_threshold: 100, noise_threshold: 20)
	src_fingerprints = fp.fingerprints(full_text)

	best_match = nil
	max_matches = 0

	subtitles.each do |key, val|
		val = val.downcase
		test_fingerprints = fp.fingerprints(val)
		
		matches = Winnow::Matcher.find_matches(src_fingerprints, test_fingerprints)

		if matches.count > max_matches
			best_match = key
			max_matches = matches.count
		end
	end

	# check for poor matching
	if max_matches < 10
		puts "Found fewer than 10 matches, giving up"
		return nil
	end

	best_match
end

main(options)
