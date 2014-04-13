require 'socket'
require 'uri'
require 'fileutils'
require 'forwardable'

class Knod
  extend Forwardable
  def_delegators :@request, :request_line

  attr_reader :server, :port, :socket, :request

  DEFAULT_PORT = 4444
  DEFAULT_WEB_ROOT = './'

  def initialize(options = {})
    @port = options[:port] || DEFAULT_PORT
    @root = options[:root] || DEFAULT_WEB_ROOT
    @server = TCPServer.new('localhost', @port)
  end

  def self.start(options = {})
    new(options).start
  end

  def start
    STDERR.puts "Starting server on port #{port}"
    loop do
      @socket = server.accept
      @request = Request.new(socket)
      STDERR.puts request_line
      public_send "do_#{requested_http_verb}"
      socket.close
    end
  end

  HTTP_VERBS = %w{GET HEAD PUT POST DELETE}

  def do_GET(head=false)
    path = requested_path
    path = File.join(path, 'index.html') if File.directory?(path)

    if is_file?(path)
      File.open(path, 'rb') do |file|
        socket.print file_response_header(file)
        IO.copy_stream(file, socket) unless head
      end
    else
      message = "\"File not found\""
      socket.print response_header(404, message)
      socket.print message unless head
    end
  end

  def do_HEAD
    do_GET(head=true)
  end

  def do_DELETE
    path = requested_path
    File.delete(path) if is_file?(path)
    socket.print response_header(204)
  end

  def do_PUT
    path = requested_path
    directory = File.dirname(path)
    FileUtils.mkdir_p(directory)
    File.write(path, request.body)
    socket.print response_header(204)
  end

  def do_POST
    path = requested_path
    FileUtils.mkdir_p(path)
    records = Dir.glob(path + "/*.json")
    next_id = (records.map {|r| File.basename(r, ".json") }.map(&:to_i).max || 0) + 1
    File.write(File.join(path, "#{next_id}.json"), request.body)
    message = "{\"id\":#{next_id}}"
    socket.print response_header(201, message)
    socket.print message
  end

  private

  STATUS_CODE_MAPPINGS = {
    200 => "OK",
    201 => "Created",
    204 => "No Content",
    404 => "Not Found",
    500 => "Internal Server Error",
    501 => "Not Implemented"
  }

  def response_header(status_code, message='')
    header = "HTTP/1.1 #{status_code} #{STATUS_CODE_MAPPINGS[status_code]}\r\n"
    header << "Content-Type: application/json\r\n" unless message.empty?
    header << "Content-Length: #{message.size}\r\n"
    header << "Connection: close\r\n\r\n"
  end

  def file_response_header(file)
    "HTTP/1.1 200 OK\r\n" <<
    "Content-Type: #{content_type(file)}\r\n" <<
    "Content-Length: #{file.size}\r\n" <<
    "Connection: close\r\n\r\n"
  end

  def is_file?(path)
    File.exist?(path) && !File.directory?(path)
  end

  def requested_http_verb
    HTTP_VERBS.find {|verb| request_line.start_with? verb}
  end

  CONTENT_TYPE_MAPPING = {
    'json' => 'application/json',
    'bmp'  => 'image/bmp',
    'gif'  => 'image/gif',
    'jpg'  => 'image/jpeg',
    'png'  => 'image/png',
    'css'  => 'text/css',
    'html' => 'text/html',
    'txt'  => 'text/plain',
    'xml'  => 'text/xml'
  }

  DEFAULT_CONTENT_TYPE = 'application/octet-stream'

  def content_type(path)
    ext = File.extname(path).split('.').last
    CONTENT_TYPE_MAPPING[ext] || DEFAULT_CONTENT_TYPE
  end

  def requested_path
    local_path = URI.unescape(URI(request.uri).path)

    clean = []

    parts = local_path.split("/")

    parts.each do |part|
      next if part.empty? || part == '.'
      part == '..' ? clean.pop : clean << part
    end

    File.join(@root, *clean)
  end
end

class Request
  attr_reader :socket, :headers, :request_line

  def initialize(socket)
    @socket = socket
    @request_line = socket.gets
    parse_request
  end

  def parse_request
    headers = {}
    loop do
      line = socket.gets
      break if line == "\r\n"
      name, value = line.strip.split(": ")
      headers[name] = value
    end
    @headers = headers
  end

  def content_length
    headers["Content-Length"].to_i
  end

  def content_type
    headers["Content-Type"]
  end

  def uri
    @uri ||= request_line.split[1]
  end

  def body
    @body ||= socket.read(content_length)
  end
end

if __FILE__ == $0
  Knod.start
end
