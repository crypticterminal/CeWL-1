#!/usr/bin/ruby1.8

# == CeWL: Custom Word List Generator
#
# CeWL will spider a target site and generate up to three lists:
#
# * A word list of all unique words found on the target site
# * A list of all email addresses found in mailto links
# * A list of usernames/author details from meta data found in any documents on the site
#
# == Usage
#
# cewl [OPTION] ... URL
#
# -h, --help:
#	show help
#
# --depth x, -d x:
#	depth to spider to, default 2
#
# --min_word_length, -m:
#	minimum word length, default 3
#
# --email file, -e
# --email_file file: 
#	include any email addresses found duing the spider, email_file is optional output file, if 
#	not included the output is added to default output
#
# --meta file, -a
# --meta_file file:
#	include any meta data found during the spider, meta_file is optional output file, if 
#	not included the output is added to default output
#
# --no-words, -n
#	don't output the wordlist
#
# --offsite, -o:
#	let the spider visit other sites
#
# --write, -w file:
#	write the words to the file
#
# --ua, -u user-agent:
#	useragent to send
#
# --meta-temp-dir directory:
#	the temporary directory used by exiftool when parsing files, default /tmp
#
# --keep, -k:
#   keep the documents that are downloaded
#
# --count, -c:
#   show the count for each of the words found
#
# -v
#	verbose
#
# URL: The site to spider.
#
# Author:: Robin Wood (robin@digininja.org)
# Copyright:: Copyright (c) Robin Wood 2012
# Licence:: GPL
#

require "rubygems"
require 'getoptlong'
require 'spider'
require 'nokogiri'
require 'http_configuration'
require '/usr/share/cewl/cewl_lib'

# Doing this so I can override the allowed? fuction which normally checks
# the robots.txt file
class MySpider<Spider
	# Create an instance of MySpiderInstance rather than SpiderInstance
	def self.start_at(a_url, &block)
		rules = RobotRules.new('Ruby Spider 1.0')
		a_spider = MySpiderInstance.new({nil => a_url}, [], rules, [])
		block.call(a_spider)
		a_spider.start!
	end
end

# My version of the spider class which allows all files
# to be processed
class MySpiderInstance<SpiderInstance
	# Force all files to be allowed
	def allowed?(a_url, parsed_url)
		true
	end
	def start! #:nodoc: 
		interrupted = false
		trap("SIGINT") { interrupted = true } 
		begin
			next_urls = @next_urls.pop
			tmp_n_u = {}
			next_urls.each do |prior_url, urls|
				x = []
				urls.each_line do |a_url|
					x << [a_url, (URI.parse(a_url) rescue nil)]
				end
				y = []
				x.select do |a_url, parsed_url|
					y << [a_url, parsed_url] if allowable_url?(a_url, parsed_url)
				end
				y.each do |a_url, parsed_url|
					@setup.call(a_url) unless @setup.nil?
					get_page(parsed_url) do |response|
						do_callbacks(a_url, response, prior_url)
						#tmp_n_u[a_url] = generate_next_urls(a_url, response)
						#@next_urls.push tmp_n_u
						generate_next_urls(a_url, response).each do |a_next_url|
							#puts 'pushing ' + a_next_url
							@next_urls.push a_url => a_next_url
						end
						#exit if interrupted
					end
					@teardown.call(a_url) unless @teardown.nil?
					exit if interrupted
				end
			end
		end while !@next_urls.empty?
	end

  def get_page(parsed_url, &block) #:nodoc:
    @seen << parsed_url
    begin
      http = Net::HTTP.new(parsed_url.host, parsed_url.port)
      if parsed_url.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      # Uses start because http.finish cannot be called.
      r = http.start {|h| h.request(Net::HTTP::Get.new(parsed_url.request_uri, @headers))}
      if r.redirect?
		base_url = parsed_url.to_s[0, parsed_url.to_s.rindex('/')]
        new_url = URI.parse(construct_complete_url(base_url,r['Location']))
		@next_urls.push parsed_url.to_s => new_url.to_s
      else
        block.call(r)
      end
    rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError => e
      p e
      nil
    end
  end
	# overriding so that I can get it to ingore direct names - i.e. #name
	def construct_complete_url(base_url, additional_url, parsed_additional_url = nil) #:nodoc:
		if additional_url =~ /^#/
			return nil
		end
		parsed_additional_url ||= URI.parse(additional_url)
		case parsed_additional_url.scheme
			when nil
				u = base_url.is_a?(URI) ? base_url : URI.parse(base_url)
				if additional_url[0].chr == '/'
					"#{u.scheme}://#{u.host}#{additional_url}"
				elsif u.path.nil? || u.path == ''
					"#{u.scheme}://#{u.host}/#{additional_url}"
				elsif u.path[0].chr == '/'
					"#{u.scheme}://#{u.host}#{u.path}/#{additional_url}"
				else
					"#{u.scheme}://#{u.host}/#{u.path}/#{additional_url}"
				end
			else
				additional_url
		end
	end

	# Overriding the original spider one as it doesn't find hrefs very well
	def generate_next_urls(a_url, resp) #:nodoc:
		web_page = resp.body
		if URI.parse(a_url).path == ""
			base_url = a_url
		else
			base_url = a_url[0, a_url.rindex('/')]
		end

		doc = Nokogiri::HTML(web_page)
		links = doc.css('a').map{ |a| a['href'] }
		links.map do |link|
			begin
				if link.nil?
					nil
				else
					begin
						parsed_link = URI.parse(link)
						if parsed_link.fragment == '#'
							nil
						else
							construct_complete_url(base_url, link, parsed_link)
						end
					rescue
						nil
					end
				end
			rescue => e
				puts "There was an error generating URL list"
				puts "Error: " + e.inspect
				puts e.backtrace
				exit
			end
		end.compact
	end
end

# A node for a tree
class TreeNode
	attr :value
	attr :depth
	attr :key
	attr :visited, true
	def initialize(key, value, depth)
		@key=key
		@value=value
		@depth=depth
		@visited=false
	end

	def to_s
		if key==nil
			return "key=nil value="+@value+" depth="+@depth.to_s+" visited="+@visited.to_s
		else
			return "key="+@key+" value="+@value+" depth="+@depth.to_s+" visited="+@visited.to_s
		end
	end
	def to_url_hash
		return({@key=>@value})
	end
end

# A tree structure
class Tree
	attr :data
	@max_depth
	@children

	# Get the maximum depth the tree can grow to
	def max_depth
		@max_depth
	end

	# Set the max depth the tree can grow to
	def max_depth=(val)
		@max_depth=Integer(val)
	end
	
	# As this is used to work out if there are any more nodes to process it isn't a true empty
	def empty?
		if !@data.visited
			return false
		else
			@children.each { |node|
				if !node.data.visited
					return false
				end
			}
		end
		return true
	end

	# The constructor
	def initialize(key=nil, value=nil, depth=0)
		@data=TreeNode.new(key,value,depth)
		@children = []
		@max_depth = 2
	end

	# Itterator
	def each
		yield @data
			@children.each do |child_node|
			child_node.each { |e| yield e }
		end
	end

	# Remove an item from the tree
	def pop
		if !@data.visited
			@data.visited=true
			return @data.to_url_hash
		else
			@children.each { |node|
				if !node.data.visited
					node.data.visited=true
					return node.data.to_url_hash
				end
			}
		end
		return nil
	end

	# Push an item onto the tree
	def push(value)
		key=value.keys.first
		value=value.values_at(key).first

		if key==nil
			@data=TreeNode.new(key,value,0)
		else
			# if the depth is 0 then don't add anything to the tree
			if @max_depth == 0
				return
			end
			if key==@data.value
				child=Tree.new(key,value, @data.depth+1)
				@children << child
			else
				@children.each { |node|
					if node.data.value==key && node.data.depth<@max_depth
						child=Tree.new(key,value, node.data.depth+1)
						@children << child
					end
				}
			end
		end
	end
end

opts = GetoptLong.new(
	[ '--help', '-h', GetoptLong::NO_ARGUMENT ],
	[ '--keep', '-k', GetoptLong::NO_ARGUMENT ],
	[ '--depth', '-d', GetoptLong::OPTIONAL_ARGUMENT ],
	[ '--min_word_length', "-m" , GetoptLong::REQUIRED_ARGUMENT ],
	[ '--no-words', "-n" , GetoptLong::NO_ARGUMENT ],
	[ '--offsite', "-o" , GetoptLong::NO_ARGUMENT ],
	[ '--write', "-w" , GetoptLong::REQUIRED_ARGUMENT ],
	[ '--ua', "-u" , GetoptLong::REQUIRED_ARGUMENT ],
	[ '--meta-temp-dir', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--meta_file', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--email_file', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--meta', "-a" , GetoptLong::NO_ARGUMENT ],
	[ '--email', "-e" , GetoptLong::NO_ARGUMENT ],
	[ '--count', '-c', GetoptLong::NO_ARGUMENT ],
	[ "-v" , GetoptLong::NO_ARGUMENT ]
)

# Display the usage
def usage
	puts"cewl 4.3 Robin Wood (robin@digininja.org) (www.digininja.org)

Usage: cewl [OPTION] ... URL
	--help, -h: show help
	--keep, -k: keep the downloaded file
	--depth x, -d x: depth to spider to, default 2
	--min_word_length, -m: minimum word length, default 3
	--offsite, -o: let the spider visit other sites
	--write, -w file: write the output to the file
	--ua, -u user-agent: useragent to send
	--no-words, -n: don't output the wordlist
	--meta, -a include meta data
	--meta_file file: output file for meta data
	--email, -e include email addresses
	--email_file file: output file for email addresses
	--meta-temp-dir directory: the temporary directory used by exiftool when parsing files, default /tmp
	--count, -c: show the count for each word found
	-v: verbose

	URL: The site to spider.

"
	exit
end

verbose=false
ua=nil
url = nil
outfile = nil
email_outfile = nil
meta_outfile = nil
offsite = false
depth = 2
min_word_length=3
email=false
meta=false
wordlist=true
meta_temp_dir="/tmp/"
keep=false
show_count = false

begin
	opts.each do |opt, arg|
		case opt
		when '--help'
			usage
		when "--count"
			show_count = true
		when "--meta-temp-dir"
			if !File.directory?(arg)
				puts "Meta temp directory is not a directory\n"
				exit
			end
			if !File.writable?(arg)
				puts "The meta temp directory is not writable\n"
				exit
			end
			meta_temp_dir=arg
			if meta_temp_dir !~ /.*\/$/
				meta_temp_dir+="/"
			end
		when "--keep"
			keep=true
		when "--no-words"
			wordlist=false
		when "--meta_file"
			meta_outfile = arg
		when "--meta"
			meta=true
		when "--email_file"
			email_outfile = arg
		when "--email"
			email=true
		when '--min_word_length'
			min_word_length=arg.to_i
			if min_word_length<1
				usage
			end
		when '--depth'
			depth=arg.to_i
			if depth < 0
				usage
			end
		when '--offsite'
			offsite=true
		when '--ua'
			ua=arg
		when '-v'
			verbose=true
		when '--write'
			outfile=arg
		end
	end
rescue
	usage
end

if ARGV.length != 1
	puts "Missing url argument (try --help)"
	exit 0
end

url = ARGV.shift

# Must have protocol
if url !~ /^http(s)?:\/\//
	url="http://"+url
end

# The spider doesn't work properly if there isn't a / on the end
if url !~ /\/$/
#	Commented out for Yori
#	url=url+"/"
end

word_hash = {}
email_arr=[]
url_stack=Tree.new
url_stack.max_depth=depth
usernames=Array.new()

# Do the checks here so we don't do all the processing then find we can't open the file
if !outfile.nil?
	begin
		outfile_file=File.new(outfile,"w")
	rescue
		puts "Couldn't open the output file for writing"
		exit
	end
else
	outfile_file=$stdout
end

if !email_outfile.nil? and email
	begin
		email_outfile_file=File.new(email_outfile,"w")
	rescue
		puts "Couldn't open the email output file for writing"
		exit
	end
else
	email_outfile_file = outfile_file
end

if !meta_outfile.nil? and email
	begin
		meta_outfile_file=File.new(meta_outfile,"w")
	rescue
		puts "Couldn't open the metadata output file for writing"
		exit
	end
else
	meta_outfile_file = outfile_file
end

begin
	# If you want to use a proxy, uncomment the next 2 lines and the matching end near the bottom
	#http_conf = Net::HTTP::Configuration.new(:proxy_host => '<Proxy server here>', :proxy_port => <Proxy port here>)
	#http_conf.apply do
		if verbose
			puts "Starting at " + url
		end

		MySpider.start_at(url) do |s|
			if ua!=nil
				s.headers['User-Agent'] = ua
			end

			s.add_url_check do |a_url|
				#puts "checking page " + a_url
				allow=true
				# Extensions to ignore
				if a_url =~ /(\.zip$|\.gz$|\.zip$|\.bz2$|\.png$|\.gif$|\.jpg$|^#)/
					if verbose
						puts "Ignoring internal link or graphic: "+a_url
					end
					allow=false
				else
					if /^mailto:(.*)/i.match(a_url)
						if email
							email_arr<<$1
							if verbose
								puts "Found #{$1} on page #{a_url}"
							end
						end
						allow=false
					else
						if !offsite
							a_url_parsed = URI.parse(a_url)
							url_parsed = URI.parse(url)
#							puts 'comparing ' + a_url + ' with ' + url

							allow = (a_url_parsed.host == url_parsed.host)

							if !allow && verbose
								puts "Offsite link, not following: "+a_url
							end
						end
					end
				end
				allow
			end

			s.on :success do |a_url, resp, prior_url|

				if verbose
					if prior_url.nil?
						puts "Visiting: #{a_url}, got response code #{resp.code}"
					else
						puts "Visiting: #{a_url} referred from #{prior_url}, got response code #{resp.code}"
					end
				end
				body=resp.body.to_s

				# get meta data
				if /.*<meta.*description.*content\s*=[\s'"]*(.*)/i.match(body)
					description=$1
					body += description.gsub(/[>"\/']*/, "") 
				end 

				if /.*<meta.*keywords.*content\s*=[\s'"]*(.*)/i.match(body)
					keywords=$1
					body += keywords.gsub(/[>"\/']*/, "") 
				end 

#				puts body
#				while /mailto:([^'">]*)/i.match(body)
#					email_arr<<$1
#					if verbose
#						puts "Found #{$1} on page #{a_url}"
#					end
#				end 

				while /(location.href\s*=\s*["']([^"']*)['"];)/i.match(body)
					full_match = $1
					j_url = $2
					if verbose
						puts "Javascript redirect found " + j_url
					end

					re = Regexp.escape(full_match)

					body.gsub!(/#{re}/,"")

					if j_url !~ /https?:\/\//i

# Broken, needs real domain adding here

						domain = "http://ninja.dev/"
						j_url = domain + j_url
						if verbose
							puts "Relative URL found, adding domain to make " + j_url
						end
					end

					x = {a_url=>j_url}
					url_stack.push x
				end

				# strip comment tags
				body.gsub!(/<!--/, "")
				body.gsub!(/-->/, "")

				# If you want to add more attribute names to include, just add them to this array
				attribute_names = [
									"alt",
									"title",
								]

				attribute_text = ""

				attribute_names.each { |attribute_name|
					body.gsub!(/#{attribute_name}="([^"]*)"/) { |attr| attribute_text += $1 + " " }
				}

				if verbose
					puts "Attribute text found:"
					puts attribute_text
					puts
				end

				body += " " + attribute_text

				# strip html tags
				words=body.gsub(/<\/?[^>]*>/, "") 

				# check if this is needed
				words.gsub!(/&[a-z]*;/, "") 

				# may want 0-9 in here as well in the future but for now limit it to a-z so
				# you can't sneak any nasty characters in
				if /.*\.([a-z]+)(\?.*$|$)/i.match(a_url)
					file_extension=$1
				else
					file_extension=""
				end

				if meta
					begin
						if keep and file_extension =~ /^((doc|dot|ppt|pot|xls|xlt|pps)[xm]?)|(ppam|xlsb|xlam|pdf|zip|gz|zip|bz2)$/
							if /.*\/(.*)$/.match(a_url)
								output_filename=meta_temp_dir+$1
								if verbose
									puts "Keeping " + output_filename
								end
							else
								# shouldn't ever get here as the regex above should always be able to pull the filename out of the url, 
								# but just in case
								output_filename=meta_temp_dir+"cewl_tmp"
								output_filename += "."+file_extension unless file_extension==""
							end
						else
							output_filename=meta_temp_dir+"cewl_tmp"
							output_filename += "."+file_extension unless file_extension==""
						end
						out=File.new(output_filename, "w")
						out.print(resp.body)
						out.close

						meta_data=process_file(output_filename, verbose)
						if(meta_data!=nil)
							usernames+=meta_data
						end
					rescue => e
						puts "Couldn't open the meta temp file for writing - " + e.inspect
						exit
					end
				end

				# don't get words from these file types. Most will have been blocked by the url_check function but
				# some are let through, such as .css, so that they can be checked for email addresses

				# this is a bad way to do this but it is either white or black list extensions and 
				# the list of either is quite long, may as well black list and let extra through
				# that can then be weeded out later than stop things that could be useful
				begin
					if file_extension !~ /^((doc|dot|ppt|pot|xls|xlt|pps)[xm]?)|(ppam|xlsb|xlam|pdf|zip|gz|zip|bz2|css|png|gif|jpg|#)$/
						begin
							if email
								# Split the file down based on the email address regexp
								#words.gsub!(/\b([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4})\b/i)
								#p words

								# If you want to pull email addresses from the contents of files found, such as word docs then move
								# this block outside the if statement
								# I've put it in here as some docs contain email addresses that have nothing to do with the target
								# so give false positive type results
								words.each_line do |word|
									while /\b([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4})\b/i.match(word)
										if verbose
											puts "Found #{$1} on page #{a_url}"
										end
										email_arr<<$1
										word=word.gsub(/#{$1}/, "")
									end
								end
							end
						rescue => e
							puts "There was a problem generating the email list"
							puts "Error: " + e.inspect
							puts e.backtrace
						end
					
						# remove any symbols
						words.gsub!(/[^a-z0-9]/i," ")
						# add to the array
						words.split(" ").each do |word|
							if word.length >= min_word_length
								if !word_hash.has_key?(word)
									word_hash[word] = 0
								end
								word_hash[word] += 1
							end
						end
					end
				rescue => e
					puts "There was a problem handling word generation"
					puts "Error: " + e.inspect
				end
			end
			s.store_next_urls_with url_stack

		end
	#end
rescue => e
	puts "Couldn't access the site"
	puts "Error: " + e.inspect
	puts e.backtrace
	exit
end

sorted_wordlist = word_hash.sort_by do |word, count| -count end
sorted_wordlist.each do |word, count|
	if show_count
		outfile_file.puts word + ', ' + count.to_s
	else
		outfile_file.puts word
	end
end

if email
	email_arr.delete_if { |x| x.chomp==""}
	email_arr.uniq!
	email_arr.sort!

	if (wordlist||verbose) && email_outfile.nil?
		outfile_file.puts
	end
	if email_outfile.nil?
		outfile_file.puts "Email addresses found"
		outfile_file.puts email_arr.join("\n")
	else
		email_outfile_file.puts email_arr.join("\n")
	end
end

if meta
	usernames.delete_if { |x| x.chomp==""}
	usernames.uniq!
	usernames.sort!

	if (email||wordlist) && meta_outfile.nil?
		outfile_file.puts
	end
	if meta_outfile.nil?
		outfile_file.puts "Meta data found"
		outfile_file.puts usernames.join("\n")
	else
		meta_outfile_file.puts usernames.join("\n")
	end
end

if meta_outfile!=nil
	meta_outfile_file.close
end

if email_outfile!=nil
	email_outfile_file.close
end

if outfile!=nil
	outfile_file.close
end
