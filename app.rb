require 'oauth'
require 'tumblr_client'
require 'curses'

require './settings.rb'


class Login
  def xAuth(user, pass)
    begin
      xauth_consumer = OAuth::Consumer.new(Settings::CONSUMER_KEY, Settings::CONSUMER_SECRET, { :site => Settings::ENDPOINT })
      xauth_token = xauth_consumer.get_access_token(nil, {}, :x_auth_mode => 'client_auth', :x_auth_username => Settings::USER, :x_auth_password => Settings::PASS)
      xauth_token
    rescue
      nil
    end
  end

  def tumblr_client(token)
    Tumblr.configure do |c|
      c.consumer_key = token.consumer.key
      c.consumer_secret = token.consumer.secret
      c.oauth_token = token.token
      c.oauth_token_secret = token.secret
    end
    Tumblr::Client.new
  end

  def curses
    client = nil

    require 'rbcurse'
    require 'rbcurse/core/widgets/rmessagebox'
    VER::start_ncurses  # this is initializing colors via ColorMap.setup
    $log = Logger.new((File.join(ENV["LOGDIR"] || "./" ,"rbc13.log")))
    $log.level = Logger::DEBUG

    @window = VER::Window.root_window
    @form = Form.new @window
    loop do
      @mb = MessageBox.new :width => 30, :height => 18 do
        title "Login"
        item Label.new :row => 1, :text => "Email"
        add Field.new :name => 'username', :row => 2, :bgcolor => :cyan, :default => Settings::USER
        item Label.new :row => 3, :text => "Password"
        add Field.new :name => 'password', :row => 4, :bgcolor => :cyan, :show => '*', :default => Settings::PASS
        button_type :ok_cancel
      end
      if @mb.run == 0
        token = xAuth(@mb.widget('username').text, @mb.widget('password').text)
        if token
          client = tumblr_client(token)
          break
        else
          alert 'Sometimes I forget my password too.'
        end
      else
        break
      end
    end

    client
  end
end

class String
  # Credit: Ruby on Rails 4.2.2 - ActionView::Helpers::TextHelper#word_wrap
  def wrap(line_width = 80)
    split("\n").collect! do |line|
      line.length > line_width ? line.gsub(/(.{1,#{line_width}})(\s+|$)/, "\\1\n").strip : line
    end * "\n"
  end
end


class Screen
  def open(&block)
    Curses.init_screen
    Curses.noecho
    Curses.timeout=0 # use non-blocking read and poll with getch
    yield self
  ensure
    Curses.clear
    Curses.close_screen
  end

  def height
    Curses.stdscr.maxy
  end

  def width
    Curses.stdscr.maxx
  end

  def paint(buffer)
    buffer.each_with_index do |line, row|
      Curses.setpos(row, 0)
      Curses.addstr(line)
    end
  end
end

class Keyboard
  SEQUENCE_TIMEOUT = 0.005

  def self.fetch_user_input
    key = Curses.getch || nil
    key.chr unless key.nil? || key.ord > 255
  end

  def self.output(options={}, &block)
    @sequence = []
    @started = Time.now.to_f
    timeout = options[:timeout]

    if timeout && SEQUENCE_TIMEOUT > timeout
      raise "Timeout must be higher then SEQUENCE_TIMEOUT (#{SEQUENCE_TIMEOUT})"
    end

    loop do
      @now = Time.now.to_f
      @elapsed = @now - @started

      key = fetch_user_input

      # finish previous sequence
      if @sequence.any? and @elapsed > SEQUENCE_TIMEOUT
        @sequence.each(&block)
        @sequence = []
      end

      if key # start new sequence
        @started = @now
        @sequence << key
      elsif timeout and @elapsed > timeout
        @started = @now
        yield :timeout
      else
        sleep SEQUENCE_TIMEOUT # nothing happening -> sleep a bit to save cpu
      end
    end
  end

end


class Form
  
  attr_accessor :parent, :children

  attr_accessor :row, :col
  
  # height or width of 0  ->  fill as much as necessary
  # height or width <= 1  ->  fill fraction of parent
  attr_accessor :height, :width

  attr_accessor :content

  def initialize(screen)
    @screen = screen
    @row = @col = 0
    @height = @width = 0
    @children = []
    @content = ''
  end

  def real_height
    if @height > 1
      @height
    elsif @height > 0
      @height * @parent.real_height
    else
      real_content.lines.count
    end
  end

  def real_width
    if @width > 1
      @width
    elsif @width > 0
      @width * @parent.real_width
    else
      content.split("\n").max{|x| x.length}.length
    end
  end

  def real_content
    content.split("\n")
  end

  def draw
    buffer = Array.new(@height) { " " * @width }
    if not @children.empty?
      cur_row = @row
      @children.each do |c|
        c.real_content.each do |line|
          child_row = cur_row + c.row
          child_col = @col + c.col
          if child_row >= 0 && child_row < @height && child_col >= 0 && child_col < @width
            line.chars.each_with_index { |c,i| buffer[child_row][child_col + i] = c if child_col+i >= 0 && child_col+i < @width}
          end
          cur_row += 1
        end
        cur_row += 2
      end
    end
    @screen.paint(buffer)
  end
end

class Post < Form
  
  def initialize(screen, parent, post)
    super(screen)
    @parent = parent
    @height = @width = 1

    @elements = case post['type']
      when 'text' then
        [ post['title'], post['body'] ]
      when 'link' then
        elements = [ post['title'], post['url'] ]
        elements << Image.new(post['link_image'], 20) if post.include? 'link_image'
      when 'photo' then
        [ post['caption'], Image.new(post['photos'][0]['original_size']['url'], real_width-10) ]
      else
        [ "POST TYPE IM NOT PARSING: #{post['type']}" ]
    end
  end

  def content
    @elements.map { |x|
      case x
        when String then
          x.to_s.wrap(real_width)
        when Image then
          x.to_s
        else
          ''
      end
    }.join("\n---\n")
  end
end

class Separator < Form
  def initialize(screen, parent)
    super(screen)
    @parent = parent
    @height = @width = 1
    @content = ('==' * real_width)
  end
end

class Image

  def initialize(url, width)
    @current_frame_index = 0
    if url.end_with? '.gif'
      `convert "#{url}" -coalesce -set dispose previous /tmp/termblr_%05d.jpg`
      all_jpg = `ls /tmp/termblr_*.jpg`.split(/\s/).sort
      @frames = all_jpg.map{|x| `jp2a --width=#{width} #{x}`}
      `rm /tmp/termblr_*.jpg`
    else
      ascii = `convert "#{url}" jpg:- | jp2a --width=#{width} -`
      @frames = [ ascii ]
    end
  end

  def current_frame
    if not @frames.empty?
      if @current_frame_index >= @frames.length
        @current_frame_index = 0
      end

      frame = @frames[@current_frame_index]
      @current_frame_index +=1
    else
      frame = ''
    end

    frame
  end

  alias to_s current_frame
end


# Only automatically fire up curses if running from a script
if __FILE__ == $0
  @client = Login.new.curses
  exit if @client.nil?

  Screen.new.open do |screen|
    base = Form.new screen
    base.height = screen.height
    base.width = 100
    if posts = @client.tagged("gif", :limit => 10, :filter => 'text')#, :type => 'photo')
      #if posts = @client.posts("staff.tumblr.com", :limit => 10, :filter => 'text')#, :type => 'photo')
      #if posts = @client.dashboard
      #@dashboard = Container.new @form, :height => 80, :width => 80, :row => 2, :col => ((FFI::NCurses.COLS-80)/2).floor, :suppress_borders => true, :positioning => :absolute
      #s = stack :name => 'dashboard', :width => 80, :row => 2, :col => ((FFI::NCurses.COLS-80)/2).floor do
      #c = Container.new @form, :height => 40, :width => 40, :row => 1, :col => 1 do
      elems = posts.each do |post|
        base.children.push(Post.new screen, base, post)
        base.children.push(Separator.new screen, base)
      end
    end

    base.draw
    Curses.refresh

    loop do
      input = Curses.getch

      if (keyboard = input.chr unless input.nil? or input.ord > 255)
        case keyboard
        when 'k' then base.row += 5
        when 'j' then base.row -= 5
        when 'q' then exit
        end
      end


      # if mouse stuff, do that

      base.draw
      Curses.refresh

      # Aim for 5Hz
      sleep 1/5.0
    end
  end
end
