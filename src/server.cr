require "kemal"
require "./context"
require "./auth_handler"
require "./static_handler"
require "./log_handler"
require "./util"

class Server
	def initialize(@context : Context)

		error 403 do |env|
			message = "You are not authorized to visit #{env.request.path}"
			layout "message"
		end

		get "/" do |env|
			titles = @context.library.titles
			username = get_username env
			percentage = titles.map &.load_percetage username
			layout "index"
		end

		get "/book/:title" do |env|
			begin
				title = (@context.library.get_title env.params.url["title"])
					.not_nil!
				username = get_username env
				percentage = title.entries.map { |e|
					title.load_percetage username, e.title }
				layout "title"
			rescue e
				@context.error e
				env.response.status_code = 404
			end
		end

		get "/admin" do |env|
			layout "admin"
		end

		get "/admin/user" do |env|
			users = @context.storage.list_users
			username = get_username env
			layout "user"
		end

		get "/admin/user/edit" do |env|
			username = env.params.query["username"]?
			admin = env.params.query["admin"]?
			if admin
				admin = admin == "true"
			end
			error = env.params.query["error"]?
				current_user = get_username env
			new_user = username.nil? && admin.nil?
			layout "user-edit"
		end

		post "/admin/user/edit" do |env|
			# creating new user
			begin
				username = env.params.body["username"]
				password = env.params.body["password"]
				# if `admin` is unchecked, the body hash
				# 	would not contain `admin`
				admin = !env.params.body["admin"]?.nil?

				if username.size < 3
					raise "Username should contain at least 3 characters"
				end
				if (username =~ /^[A-Za-z0-9_]+$/).nil?
					raise "Username should contain alphanumeric characters "\
						"and underscores only"
				end
				if password.size < 6
					raise "Password should contain at least 6 characters"
				end
				if (password =~ /^[[:ascii:]]+$/).nil?
					raise "password should contain ASCII characters only"
				end

				@context.storage.new_user username, password, admin

				env.redirect "/admin/user"
			rescue e
				@context.error e
				redirect_url = URI.new \
					path: "/admin/user/edit",\
					query: hash_to_query({"error" => e.message})
				env.redirect redirect_url.to_s
			end
		end

		post "/admin/user/edit/:original_username" do |env|
			# editing existing user
			begin
				username = env.params.body["username"]
				password = env.params.body["password"]
				# if `admin` is unchecked, the body
				#	hash would not contain `admin`
				admin = !env.params.body["admin"]?.nil?
				original_username = env.params.url["original_username"]

				if username.size < 3
					raise "Username should contain at least 3 characters"
				end
				if (username =~ /^[A-Za-z0-9_]+$/).nil?
					raise "Username should contain alphanumeric characters "\
						"and underscores only"
				end

				if password.size != 0
					if password.size < 6
						raise "Password should contain at least 6 characters"
					end
					if (password =~ /^[[:ascii:]]+$/).nil?
						raise "password should contain ASCII characters only"
					end
				end

				@context.storage.update_user \
					original_username, username, password, admin

				env.redirect "/admin/user"
			rescue e
				@context.error e
				redirect_url = URI.new \
					path: "/admin/user/edit",\
					query: hash_to_query({"username" => original_username, \
						   "admin" => admin, "error" => e.message})
					env.redirect redirect_url.to_s
			end
		end


		get "/reader/:title/:entry" do |env|
			begin
				title = (@context.library.get_title env.params.url["title"])
					.not_nil!
				entry = (title.get_entry env.params.url["entry"]).not_nil!

				# load progress
				username = get_username env
				page = title.load_progress username, entry.title
				# we go back 2 * `IMGS_PER_PAGE` pages. the infinite scroll
				# 	library perloads a few pages in advance, and the user
				# 	might not have actually read them
				page = [page - 2 * IMGS_PER_PAGE, 1].max

				env.redirect "/reader/#{title.title}/#{entry.title}/#{page}"
			rescue e
				@context.error e
				env.response.status_code = 404
			end
		end

		get "/reader/:title/:entry/:page" do |env|
			begin
				title = (@context.library.get_title env.params.url["title"])
					.not_nil!
				entry = (title.get_entry env.params.url["entry"]).not_nil!
				page = env.params.url["page"].to_i
				raise "" if page > entry.pages || page <= 0

				# save progress
				username = get_username env
				title.save_progress username, entry.title, page

				pages = (page...[entry.pages + 1, page + IMGS_PER_PAGE].min)
				urls = pages.map { |idx|
					"/api/page/#{title.title}/#{entry.title}/#{idx}" }
				reader_urls = pages.map { |idx|
					"/reader/#{title.title}/#{entry.title}/#{idx}" }
				next_page = page + IMGS_PER_PAGE
				next_url = next_page > entry.pages ? nil :
					"/reader/#{title.title}/#{entry.title}/#{next_page}"
				exit_url = "/book/#{title.title}"
				next_entry = title.next_entry entry
				next_entry_url = next_entry.nil? ? nil : \
					"/reader/#{title.title}/#{next_entry.title}"

				render "src/views/reader.ecr"
			rescue e
				@context.error e
				env.response.status_code = 404
			end
		end

		get "/login" do |env|
			render "src/views/login.ecr"
		end

		get "/logout" do |env|
			begin
				cookie = env.request.cookies
					.find { |c| c.name == "token" }.not_nil!
				@context.storage.logout cookie.value
			rescue e
				@context.error "Error when attempting to log out: #{e}"
			ensure
				env.redirect "/login"
			end
		end

		post "/login" do |env|
			begin
				username = env.params.body["username"]
				password = env.params.body["password"]
				token = @context.storage.verify_user(username, password)
					.not_nil!

				cookie = HTTP::Cookie.new "token", token
				env.response.cookies << cookie
				env.redirect "/"
			rescue
				env.redirect "/login"
			end
		end

		get "/api/page/:title/:entry/:page" do |env|
			begin
				title = env.params.url["title"]
				entry = env.params.url["entry"]
				page = env.params.url["page"].to_i

				t = @context.library.get_title title
				raise "Title `#{title}` not found" if t.nil?
				e = t.get_entry entry
				raise "Entry `#{entry}` of `#{title}` not found" if e.nil?
				img = e.read_page page
				raise "Failed to load page #{page} of `#{title}/#{entry}`"\
					if img.nil?

				send_img env, img
			rescue e
				@context.error e
				env.response.status_code = 500
				e.message
			end
		end

		get "/api/book/:title" do |env|
			begin
				title = env.params.url["title"]

				t = @context.library.get_title title
				raise "Title `#{title}` not found" if t.nil?

				send_json env, t.to_json
			rescue e
				@context.error e
				env.response.status_code = 500
				e.message
			end
		end

		get "/api/book" do |env|
			send_json env, @context.library.to_json
		end

		post "/api/admin/scan" do |env|
			start = Time.utc
			@context.library.scan
			ms = (Time.utc - start).total_milliseconds
			send_json env, {
				"milliseconds" => ms,
				"titles" => @context.library.titles.size
			}.to_json
		end

		post "/api/admin/user/delete/:username" do |env|
			begin
				username = env.params.url["username"]
				@context.storage.delete_user username
			rescue e
				@context.error e
				send_json env, {
					"success" => false,
					"error" => e.message
				}.to_json
			else
				send_json env, {"success" => true}.to_json
			end
		end

		post "/api/progress/:title/:entry/:page" do |env|
			begin
				username = get_username env
				title = (@context.library.get_title env.params.url["title"])
					.not_nil!
				entry = (title.get_entry env.params.url["entry"]).not_nil!
				page = env.params.url["page"].to_i

				raise "incorrect page value" if page < 0 || page > entry.pages
				title.save_progress username, entry.title, page
			rescue e
				@context.error e
				send_json env, {
					"success" => false,
					"error" => e.message
				}.to_json
			else
				send_json env, {"success" => true}.to_json
			end
		end

		Kemal.config.logging = false
		add_handler LogHandler.new @context.logger
		add_handler AuthHandler.new @context.storage
		{% if flag?(:release) %}
			# when building for relase, embed the static files in binary
			@context.debug "We are in release mode. Using embeded static files."
			serve_static false
			add_handler StaticHandler.new
		{% end %}
	end

	def start
		@context.debug "Starting Kemal server"
		{% if flag?(:release) %}
			Kemal.config.env = "production"
		{% end %}
		Kemal.config.port = @context.config.port
		Kemal.run
	end
end
