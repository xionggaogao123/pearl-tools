#!/usr/bin/env ruby -w
# -*- coding: utf-8 -*-
# A ruby script for publishing app packages to deployment repos (ftp, git, etc).

require 'net/ftp'
require 'optparse'


VERSION  = %w(0 0 2)

# ftp params
FTP_HOST = 'ftp.gm.com'
FTP_USER = 'anonymous'
FTP_PASS = ''
FTP_DIR = '/products'

# Default app publish dir
APP_PUBLISH_DIR = '/opt/scm/app-publish'
#APP_PUBLISH_DIR = '/Users/akuma/Programs/misc/app-test/git-publish'

# Valid classifiers
CLASSIFIERS = %w(test release beta alpha)

# Program name
EXECUTOR_NAME = File.basename($PROGRAM_NAME)


options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Publish app packages to deployment repos (ftp, git, etc).
Usage: #{EXECUTOR_NAME} [options] package_dir [publish_dir]"

  opts.separator ''
  opts.separator 'Common options:'

  opts.on('-n',
          '--name pkg_regex',
          'The package files, regex supports') do |pkg_regex|
    options[:pkg_regex] = pkg_regex
  end

  opts.on('-b',
          '--branch branch_name',
          'The branch name which to publish') do |branch_name|
    options[:branch_name] = branch_name
  end

  opts.on_tail('-h', '--help', 'Show this message') do
    puts opts
    exit 0
  end

  opts.on_tail('-v', '--version', 'Show version') do
    puts "#{EXECUTOR_NAME} #{VERSION.join('.')}"
    exit 0
  end
end

# Publish matched app packages to the products repos.
def publish_apps(pkg_dir, publish_dir=APP_PUBLISH_DIR, branch_name = 'master', pkg_regex = '.+\-.+\-.+\-.+')
  publish_dir = publish_dir || APP_PUBLISH_DIR
  branch_name = branch_name || 'master'
  pkg_regex = pkg_regex || '.+\-.+\-.+\-.+'

  unless Dir.exists?(pkg_dir)
    puts "Error: #{pkg_dir} is not a directory."
    exit 0
  end

  unless Dir.exists?(publish_dir)
    puts "Error: #{publish_dir} is not a directory."
    exit 0
  end

  matched_pkgs = []
  matched_dirs = []

  Dir.foreach(pkg_dir) do |x|
    next unless /#{pkg_regex}/i.match(x)
    Dir.exist?("#{pkg_dir}/#{x}") ? matched_dirs << x : matched_pkgs << x
  end

  matched_pkgs.sort
  matched_dirs.sort

  if matched_pkgs.empty? and matched_dirs.empty?
    puts "Info: Can't find any app packages with regex '#{app_regex}'."
    exit 0
  end

  Net::FTP.open(FTP_HOST) do |ftp|
    begin
      ftp.login(FTP_USER, FTP_PASS)
    rescue => e
      puts
      puts "Error: #{e}"
      puts
      break
    end

    unless matched_pkgs.empty?
      puts
      puts "Uploading all matched packages to ftp [#{FTP_HOST}]:"
      puts
    end

    matched_pkgs.each do |pkg_name|
      app_info = extract_app_info(pkg_name)
      ftp_publish(pkg_name, pkg_dir, app_info, ftp) if app_info
    end
  end

  unless matched_dirs.empty?
    puts
    puts 'Publish all matched packages to git repos:'
    puts
  end

  matched_dirs.each do |pkg_name|
    app_info = extract_app_info(pkg_name)
    git_publish(pkg_name, pkg_dir, publish_dir, app_info, branch_name) if app_info
  end

  puts
end

# Extract app info from app's package/dir name.
# There are some package name examples:
#   demo-1.1.0-r16859-release.war, demo-1.1.0-r16859-release-sql.zip
#   demo-sub-1.0.0-r16565-release.war, demo-sub-1.0.0-r16565-release-sql.zip
#   demo-1.0.0-r16565-release, demo-sub-1.0.0-r16565-release
def extract_app_info(pkg_name)
  app_info = pkg_name.split('-')
  if /(\d\.)+/.match(app_info[1])
    if app_info.size < 4
      puts "  ignore package #{pkg_name}: invalid package name"
      return
    end

    app_fullname = app_info[0]
    app_version = app_info[1]
    app_revision = app_info[2]
    app_cls_suffix = app_info[3]
  else
    if app_info.size < 5
      puts "  ignore package #{pkg_name}: invalid package name"
      return
    end

    app_fullname = app_info[0] + '-' + app_info[1]
    app_version = app_info[2]
    app_revision = app_info[3]
    app_cls_suffix = app_info[4]
  end

  # app_fullname example: demo, demo-sub
  app_type_index = app_fullname.index('_')
  app_name = app_type_index ? app_fullname[0...app_type_index] : app_fullname

  # major version example: 1.1
  app_major_version = app_version[0..2]

  # app_cls_suffix example: release, release.war, release.zip
  dot_index = app_cls_suffix.index('.')
  app_classifier = dot_index ? app_cls_suffix[0...dot_index] : app_cls_suffix

  {app_name: app_name,
    app_fullname: app_fullname,
    app_major_version: app_major_version,
    app_version: app_version,
    app_revision: app_revision,
    app_classifier: app_classifier}
end

# Publish app packages to ftp server.
def ftp_publish(pkg_name, pkg_dir, app_info, ftp)
  app_classifier = app_info[:app_classifier]
  app_name = app_info[:app_name]
  app_major_version = app_info[:app_major_version]

  remote_path = File.join(FTP_DIR, app_classifier, app_name, app_major_version)
  if ftp_mkds(ftp, remote_path)
    ftp.chdir(remote_path)
  else
    return
  end

  # Make package long name less shorter
  app_revision = app_info[:app_revision]
  pkg_short_name = pkg_name.sub(app_revision, app_revision[0..6])

  File.open(File.join(pkg_dir, pkg_name), 'rb') do |file|
    begin
      ftp.storbinary("STOR #{pkg_short_name}", file, 8196)
      puts "  #{pkg_name} => #{remote_path}/#{pkg_short_name}"
    rescue => e
      puts "  Error: #{e}"
    end
  end
end

# Publish app packages to git repos.
def git_publish(pkg_name, pkg_dir, publish_dir, app_info, branch_name)
  app_name = app_info[:app_name]
  app_fullname = app_info[:app_fullname]
  app_classifier = app_info[:app_classifier]

  unless CLASSIFIERS.include?(app_classifier)
    puts "  Ignore package #{pkg_name}: invalid classifer '#{app_classifier}'"
    return
  end

  if app_classifier == "test"
    puts "  Ignore package #{pkg_name}: classifier is 'test'"
    return
  end

  app_deploy_repos0 = "#{app_name}-deploy-#{branch_name}"
  app_deploy_dir = File.join(publish_dir, "#{app_deploy_repos0}")
  unless Dir.exist?(app_deploy_dir)
    app_deploy_repos1 = "#{app_name}-deploy"
    app_deploy_dir = File.join(publish_dir, "#{app_deploy_repos1}")
    unless Dir.exist?(app_deploy_dir)
      puts "  Ignore package #{pkg_name}: has no repos '#{app_deploy_repos0}' or '#{app_deploy_repos1}'"
      return
    end
  end

  working_dir = Dir.pwd
  puts "  Changing dir #{working_dir} -> #{app_deploy_dir}..."
  Dir.chdir(app_deploy_dir)

  # Checkout git branch
  `git checkout #{branch_name}`

  # Update package files of git repos
  pkg_full_path = File.join(working_dir, pkg_dir, pkg_name)
  puts "  Rsyncing #{pkg_full_path}/ -> #{app_deploy_dir}..."
  `rsync -vazC --progress --exclude=.* --exclude=*.java --delete #{pkg_full_path}/ .`

  # Git commit and push
  `git add .`
  `git commit -am 'Publish #{pkg_name}.'`
  `git push origin #{branch_name}`

  # Go back to working dir
  Dir.chdir(working_dir)
end

# Create dirs on ftp.
def ftp_mkds(ftp, path)
  dirs = path.split('/')[1..-1]
  dirs.each_index do |i|
    begin
      dir = "/#{dirs[0..i].join('/')}"
      ftp.chdir(dir)
    rescue
      begin
        ftp.mkdir(dir)
      rescue => e
        puts "  Error: #{e}"
        return false
      end
    end
  end

  true
end

begin
  option_parser.parse!
  #puts "options: #{options}"
  #puts "argv: #{ARGV}"

  if ARGV.empty?
    puts 'Error: you must supply the package dir'
    puts
    puts option_parser.help
  else
    pkg_dir = ARGV[0]
    publish_dir = ARGV[1]
    branch_name = options[:branch_name]
    pkg_regex = options[:pkg_regex]
    publish_apps(pkg_dir, publish_dir, branch_name, pkg_regex)
  end
rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
  puts "Error: #{e}"
  puts
  puts option_parser.help
end

