# Copyright 2013, Copperegg
#
# All rights reserved - Do Not Redistribute
#

# ----------------------------------------------------------------------- #

# manually install packages necessary for this recipe
def manual_package_install(pkg_dependencies=[])

   unless pkg_dependencies.nil?
      pkg_dependencies.each do |pkg|

         if pkg =~ /\.rpm/
            filename = $1 if pkg =~ /\/(\w+[a-zA-Z0-9\-\_\.]+\.rpm)\z/
            p "FILENAME: #{filename}"
            remote_file "#{Chef::Config[:file_cache_path]}/#{filename}" do
               source "#{pkg}"
               action :create_if_missing
            end
         end

         package pkg do
            action :install
            if pkg =~ /\.rpm/
               source "#{Chef::Config[:file_cache_path]}/#{filename}"
               provider Chef::Provider::Package::Rpm
            end
         end

      end
   end

end

# ----------------------------------------------------------------------- #

# build ssh_wrapper file for pulling ssh git repos
def ssh_wrapper(admin={}, wrapper_path="")

   template "#{wrapper_path}" do
      source "ssh_wrapper.erb"
      owner admin['uid']
      group admin['gid'] || admin['username']
      mode "0755"
      variables(
         :key_path => "#{admin['home']}/#{admin['deploy_key']}"
      )
   end

end

# ----------------------------------------------------------------------- #

# checkout branch
def checkout_branch(repo_dir="", branch="master", admin={}, ruby_env="")

   # checkout branch
   git "#{repo_dir}" do
      revision    branch
      action      :checkout
   end

   # checkout branch again to make sure
   execute "force_repo_checkout" do
      command  "git checkout -f #{branch}"
      cwd      "#{repo_dir}"
      user     admin['username']
      environment(ruby_env)
      action :run
   end

end

# ----------------------------------------------------------------------- #

# run bundler in repo
def bundle_repo(repo_dir="", admin={}, gemset="", ruby_env="" )

   bundle = "/usr/local/rvm/gems/#{gemset}/bin/bundle"
   bash "bundle_install" do
      command     "rvm gemset #{bundle} install"
      cwd         "#{repo_dir}"
      user        admin['username']
      group       "rvm"
   end

   execute "daemons_bundler" do
      user        admin['username']
      group       admin['username']
      cwd         repo_dir
      command     "rm -rf #{repo_dir}/.bundle && cd #{repo_dir} && bundle install"
      environment(ruby_env)
      action      :run
   end

end

# ----------------------------------------------------------------------- #

# pull source file
def pull_source(attrs={})
   outfile = "#{Chef::Config[:file_cache_path]}/#{attrs['src_file']}"

   def checksum_file(shasum="", filename="", error_level=0)
      (cksum, fn) = `sha256sum #{filename}`.split(/\s+/)
      if cksum != shasum
         if error_level == 0
            Chef::Application.warn("#{filename} MISMATCH DELETE/REPULL", 1)
            file "#{filename}" do
               action :delete
            end
         end
         Chef::Application.fatal!("#{filename} MISMATCH CHECKSUM", 1) if error_level == 1
      end
   end

   if attrs['url'] =~ /^ftp/
      execute "ftp_#{attrs['src_file']}" do
         command "curl #{attrs['url']} -o #{outfile}"
         creates "#{outfile}"
         action :run
      end
   else
      remote_file "#{outfile}" do
         source "#{attrs['url']}"
         checksum attrs['checksum']
         action :create_if_missing
      end
   end
end

# ----------------------------------------------------------------------- #

# compare files from source path to destination
def compare_paths(src_path, dst_path)
   match = true
   # assume linux
   md5sum = "md5sum"
   md5sum = "md5" if node.platform == "freebsd"

   lib_files = `ls #{src_path}/`.split(/\n/)
   lib_files.each do |file|
      src = `#{md5sum} #{src_path}/#{file}`.split(/\s+/)
      dst = `#{md5sum} #{dst_path}/#{file}`.split(/\s+/)
      match = false if (src[0] != dst[0])
   end
   return match
end

# ----------------------------------------------------------------------- #

# compare files from source path to destination
def compare_list(attrs={})
   match = true
   # assume linux
   md5sum = "md5sum"
   md5sum = "md5" if node.platform == "freebsd"

   attrs['compare_list'].each do |src_file, dst_file|
      src = `#{md5sum} #{Chef::Config[:file_cache_path]}/#{attrs['src_dir']}/#{src_file}`.split(/\s+/)
      dst = `#{md5sum} #{attrs['prefix']}/#{dst_file}`.split(/\s+/)
      if (src[0] != dst[0]) || src[0].nil? || dst[0].nil?
         p "#{src_file} #{attrs['prefix']}/#{dst_file}"
         p "#{src[0]} #{dst[0]}"
         match = false
      end
   end
   return match
end

# ----------------------------------------------------------------------- #

# del old source dir if it exists and extract source appropriately
def cleanup_extract_source(attrs={})

   execute "cleanup_source" do
      cwd Chef::Config[:file_cache_path]
      command "rm -rf #{attrs['src_dir']}"
      not_if do ! FileTest.directory?(attrs['src_dir']) end
      action :run
   end

   extract_flags = "tar zxf"  if attrs['src_file'] =~ /tar\.gz/
   extract_flags = "tar jxf"  if attrs['src_file'] =~ /tar\.bz2/
   extract_flags = "7za x"    if attrs['src_file'] =~ /7z/

   execute "extract_source" do
      cwd Chef::Config[:file_cache_path]
      command "#{extract_flags} #{Chef::Config[:file_cache_path]}/#{attrs['src_file']}"
      action :run
   end

end

# ----------------------------------------------------------------------- #

# configure source
def config_source(attrs={})
   execute "config_source" do
      cwd "#{Chef::Config[:file_cache_path]}/#{attrs['src_dir']}"
      command "#{attrs['opt_flags']} ./configure #{attrs['cfg_flags']}"
      action :run
   end
end

# ----------------------------------------------------------------------- #

# make
def make(attrs={})
   execute "make_source" do
      cwd "#{Chef::Config[:file_cache_path]}/#{attrs['src_dir']}"
      command "make #{attrs['make_flags']}"
      action :run
   end
end

# ----------------------------------------------------------------------- #

# make install
def make_install(attrs={})
   execute "install_source" do
      cwd "#{Chef::Config[:file_cache_path]}/#{attrs['src_dir']}"
      command "make install #{attrs['make_install_flags']}"
      action :run
   end
end

# ----------------------------------------------------------------------- #

# run ldconfig
def ldconfig(attrs={})
   execute "ldconfig" do
      cwd "#{Chef::Config[:file_cache_path]}/#{attrs['src_dir']}"
      command "ldconfig"
      action :run
   end
end

# ----------------------------------------------------------------------- #

# def to iterate through node values and print out for debugging
def node_info()
   node.each do |k,v|
      if "#{v.class}" == "Chef::Node::ImmutableArray" || "#{v.class}" == "Chef::Node::ImmutableMash"
         puts "[#{k}]"
         v.each do |x,y|
            puts "\t#{x}\t#{y}"
         end
      else
         puts "[#{k}]\t#{v}"
      end
      puts
   end
end
