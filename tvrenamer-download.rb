# http://www.flixtools.com/en/osflixtools.subtitles-download/subtitles/:id

require 'filemagic'
require 'nokogiri'
require 'open-uri'
require 'optparse'
require 'tempfile'
require 'zip'

options = {}
opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: tvrenamer-download.rb [options]"

	opts.on "-oFILE", "--output=FILE", "Where to store the downloaded SRT file" do |f|
		options[:output] = f
	end

	opts.on "-sID", "--subtitle-id=ID", "Open subtitles ID to download" do |id|
		options[:id] = id
	end

	opts.on "-h", "--help", "Prints this help" do
		puts opts
		exit
	end
end
opt_parser.parse!

if options[:id].nil?
	puts "Error: subtitle ID is required"
	exit 1
end

url = "http://www.flixtools.com/en/osflixtools.subtitles-download/subtitles/#{options[:id]}"

page = Nokogiri::HTML(open(url))

# find the head
meta_tag = page.css('head > meta[http-equiv="refresh"]')
meta_content = meta_tag[0]['content']

matches = /URL=([^\'\"]+)/.match(meta_content)

download_url = matches[1]

zipbytes = nil
open(download_url, 'rb', 'Cookie' => "__cfduid=d4e4a0dcfbc884fe7991cdd1a667285851461777418; _ga=GA1.2.1518342391.1461777632; osub_unique_user=1; land_ft=1; pref_mk=%7B%22tv%22%3A2%2C%22m%22%3A0%7D; PHPSESSID=0ncm5gi75i8d1jumel2823d553") do |file|
	zipbytes = file.read
end

# check the file type
file_type = nil
file = Tempfile.new('tvrenamer')
begin
	file.write zipbytes
	magic = FileMagic.new
	file_type = magic.file file.path
	magic.close
ensure
	file.close
	file.unlink
end

if ! file_type.start_with? 'Zip'
	puts "Error: downloaded unknown file type from #{download_url} (#{file_type})"
	exit 1
end

srt_contents = nil

Zip::File.open_buffer(zipbytes) do |zf|
	zf.each do |entry|
		if File.extname(entry.name) == '.srt'
			# found the srt
			if ! srt_contents.nil?
				raise "Found multiple srt files in zip archive"
			end

			srt_contents = entry.get_input_stream.read
		end
	end
end

if srt_contents.nil?
	raise "Could not find srt file in zip archive: #{download_url}"
end

File.open(options[:output], 'w') do |file|
	file.write srt_contents
end
