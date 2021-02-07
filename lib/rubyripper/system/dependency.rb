#!/usr/bin/env ruby
#    Rubyripper - A secure ripper for Linux/BSD/OSX
#    Copyright (C) 2007 - 2010  Bouke Woudstra (boukewoudstra@gmail.com)
#
#    This file is part of Rubyripper. Rubyripper is free software: you can
#    redistribute it and/or modify it under the terms of the GNU General
#    Public License as published by the Free Software Foundation, either
#    version 3 of the License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>

require 'singleton'
require 'rubyripper/system/execute'

# The Dependency class is responsible for all dependency checking
class Dependency
  include Singleton unless $run_specs
  include GetText
  GetText.bindtextdomain("rubyripper")
  def self._(txt) ; GetText._(txt) ; end

  attr_reader :platform

  def initialize(file=nil, platform=nil)
    @platform = platform ? platform : RUBY_PLATFORM
    @file = file ? file : File
  end

  # should be triggered by any user interface
  def startupCheck
    checkForcedDeps()
  end

  def eject(cdrom)
    Thread.new do
      @exec = Execute.new
      if installed?('eject')
        @exec.launch("eject #{cdrom}")
      #Mac users have diskutil instead of eject
      elsif installed?('diskutil')
        @exec.launch("diskutil eject #{cdrom}")
      else
        puts _("WARNING: No eject utility found!")
      end
    end
  end

  # opposite of eject
  def closeTray(cdrom)
    if installed?('eject')
      @exec.launch("eject --trayclose #{cdrom}")
    end
  end

  # verify all dependencies are met
  # * verbose = print extra info to the terminal. Used in configure script.
  # * runtime = exit when needed deps aren't met
  def verify(verbose=false, runtime=true)
    @verbose = verbose
    @runtime = runtime
    setConsequence()
    checkForcedDeps()
    checkOptionalDeps()
    @deps = arrayToHash(@forcedDeps + @optionalDeps)

    showInfo() if verbose == true
    forceDepsRuntime() if runtime == true
  end

  def env(var)
    return ENV[var]
  end

  # an array with dirs in which binary files are launchable
  def path ; ENV['PATH'].split(':') + ['.'] ; end

  # find the default programs if not set before
  def filemanager ; getFilemanager() ; end
  def editor ; getEditor() ; end
  def browser ; getBrowser() ; end

  # find the default drive for the OS
  def cdrom ; getCdrom() ; end

  # A help function to check if an application is installed?
  def installed?(app)
    path.each do |dir|
      return true if File.exist?(File.join(dir, app))
    end
    return false
  end

private

  # fill the Hash with consequences
  def setConsequence
    @consequence = {
    'cdparanoia' => _("Rubyripper can't be used without cdparanoia!"),
      'ruby-gtk2' => _("You won't be able to use the gtk2 interface."),
      'ruby-gettext' => _("You won't be able to use translations."),
      'discid' => _("You won't have accurate freedb string \
calculation unless %s is installed.") % ['Cd-discid'],
      'cd-discid' => _("You won't have accurate freedb string \
calculation unless %s is installed.") % ['Discid'],
      'eject' => _("Your disc tray can not be opened after ripping"),
      'flac' => _("You won't be able to encode in FLAC."),
      'vorbis' => _("You won't be able to encode in vorbis."),
      'lame' => _("You won't be able to encode in LAME mp3."),
      'wavegain' => _("You won't be able to replaygain WAVE files."),
      'vorbisgain' => _("You won't be able to replaygain vorbis files."),
      'mp3gain' => _("You won't be able to replaygain LAME mp3 files."),
      'normalize' => _("You won't be able to normalize audio files."),
      'cdrdao' => _("You won't be able to make cuesheets"),
      'cd-info' => _("Cd-info helps to detect data tracks."),
      'ls' => _("Show rights in case of problems")
    }
  end

  # convert the arrays to hashes (they were array's to prevent random sorting)
  def arrayToHash(array)
    returnHash = Hash.new
    array.each{|k,v| returnHash[k]=v}
    return returnHash
  end

  # check if all the forced dependencies are there
  def checkForcedDeps()
    @forcedDeps = Array.new
    @forcedDeps << ['cdparanoia', installed?('cdparanoia')]
  end

  # check if all the optional dependencies are there
  def checkOptionalDeps()
    @optionalDeps = Array.new
    @optionalDeps << ['ruby-gtk2', isGtk2Found()]
    @optionalDeps << ['ruby-gettext', isGettextFound()]
    @optionalDeps << ['discid', installed?('discid')]
    @optionalDeps << ['cd-discid', installed?('cd-discid')]
    @optionalDeps << ['eject', installed?('eject') || installed?('diskutil')]

    # codecs
    @optionalDeps << ['flac', installed?('flac')]
    @optionalDeps << ['vorbis', installed?('oggenc')]
    @optionalDeps << ['lame', installed?('lame')]

    # replaygain / normalize
    @optionalDeps << ['wavegain', installed?('wavegain')]
    @optionalDeps << ['vorbisgain', installed?('vorbisgain')]
    @optionalDeps << ['mp3gain', installed?('mp3gain')]
    @optionalDeps << ['normalize', installed?('normalize') || installed?('normalize-audio')]

    # extra apps
    @optionalDeps << ['cdrdao', installed?('cdrdao')]
    @optionalDeps << ['cd-info', installed?('cd-info')]
    @optionalDeps << ['ls', installed?('ls')]
    @optionalDeps << ['diskutil', installed?('diskutil')]
  end

  # check for ruby-gtk2
  def isGtk2Found
    begin
      require 'gtk2'
      return true
    rescue Gtk::InitError
      return true
    rescue LoadError
      return false
    end
  end

  # check for ruby-gettext
  def isGettextFound
    begin
      require 'gettext'
      return true
    rescue LoadError
      return false
    end
  end

  # show the results in a terminal
  def showInfo
    print _("\n\nCHECKING FORCED DEPENDENCIES\n\n")
    printResults(@forcedDeps)
    print _("\nCHECKING OPTIONAL DEPENDENCIES\n\n")
    printResults(@optionalDeps)
    print "\n\n"
  end

  # iterate over the deps and show the detailInfo
  def printResults(deps)
    deps.each do |key, value|
      if value == true
        puts "#{key}: [OK]"
      else
        puts "#{key}: [NOT OK]"
        puts @consequence[key] if @consequence.key?(key)
      end
    end
  end

  # when running rubyripper make sure the forced deps are there
  def forceDepsRuntime
    if not @deps['cdparanoia']
      puts "Cdparanoia not found on your system."
      puts "This is required to run rubyripper. Exiting..."
      exit()
    end
  end

  # determine default file manager
  def getFilemanager
    case
    when ENV['DESKTOP_SESSION'] == 'kde' && installed?('dolphin') then 'dolphin'
    when ENV['DESKTOP_SESSION'] == 'kde' && installed?('konqueror') then 'konqueror'
    when installed?('thunar') then 'thunar' #Xfce4 filemanager
    when installed?('nautilus') then 'nautilus --no-desktop' #Gnome filemanager
    else 'echo'
    end
  end

  # determine default editor
  def getEditor # look for default editor
    case
    when ENV['DESKTOP_SESSION'] == 'kde' && installed?('kwrite') then 'kwrite'
    when installed?('mousepad') then 'mousepad' #Xfce4 editor
    when installed?('gedit') then 'gedit' #Gnome editor
    when ENV.key?('EDITOR') then ENV['EDITOR']
    else 'echo'
    end
  end

  # determine default browser
  def getBrowser
    case
    when installed?('chromium') then 'chromium'
    when installed?('konqueror') && ENV['DESKTOP_SESSION'] == 'kde' then 'konqueror'
    when installed?('firefox') then 'firefox'
    when installed?('epiphany') then 'epiphany'
    when installed?('opera') then 'opera'
    when ENV.key?('BROWSER') then ENV['BROWSER']
    else 'echo'
    end
  end

  # determine default drive
  def getCdrom #default values for cdrom drives under differenty os'es
    case platform
      when /freebsd/ then drive = getFreebsdDrive()
      when /openbsd/ then drive = '/dev/cd0c' # as provided in issue 324
      when /linux|bsd/ then drive = getLinuxDrive()
      when /darwin/ then drive = '/dev/disk1'
    end

    return drive ? drive : 'unknown'
  end

  def getFreebsdDrive
    (0..9).each{|num| return "/dev/cd#{num}" if @file.exist?("/dev/cd#{num}")}
    (0..9).each{|num| return "/dev/acd#{num}" if @file.exist?("/dev/acd#{num}")}
    return false
  end

  def getLinuxDrive
    return '/dev/cdrom' if @file.exist?('/dev/cdrom')
    return '/dev/dvdrom' if @file.exist?('/dev/dvdrom')
    (0..9).each{|num| return "/dev/sr#{num}" if @file.exist?("/dev/sr#{num}")}
    return false
  end
end
