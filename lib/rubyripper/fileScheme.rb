#!/usr/bin/env ruby
#    Rubyripper - A secure ripper for Linux/BSD/OSX
#    Copyright (C) 2007 - 2013  Bouke Woudstra (boukewoudstra@gmail.com)
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

# FileScheme is a helpclass that defines all the names of the directories,
# filenames and tags. It filters out special characters that are not
# well supported in the different platforms. It also offers some help
# functions to create the output dirs and to get a preview of the output.
# Since all the info is here, also create the playlist files. The cuesheets
# are also made with help of the Cuesheet class.
# Output is initialized as soon as the player pushes Rip Now!

require 'rubyripper/preferences/main'
require 'rubyripper/metadata/filter/filterDirs'
require 'rubyripper/metadata/filter/filterFiles'
require 'rubyripper/system/fileAndDir'

class FileScheme
  include GetText
  GetText.bindtextdomain("rubyripper")

  attr_reader :status, :dir

  # prefs = prefs object
  # disc = disc object
  # trackSelection = array with tracknumbers to rip
  def initialize(disc, trackSelection, prefs=nil, filterDirs=nil, filterFiles=nil, file=nil)
    @disc = disc
    @md = disc.metadata
    @trackSelection = trackSelection
    @prefs = prefs ? prefs : Preferences::Main.instance
    @filterDirs = filterDirs ? filterDirs : Metadata::FilterDirs.new(@md)
    @filterFiles = filterFiles ? filterFiles : Metadata::FilterFiles.new(@md)
    @file = file ? file : FileAndDir.instance
  end

  # cleanup the filescheme and calculate output directories
  def prepare
    setVariables()
    setFileScheme()
    correctFilescheme()
    setDirectoryForEachCodec()
    detectOtherCodecExtension()
  end

  # (re)attempt creation of the dirs, when succesfull create the filenames
  def createFileAndDirs()
    createOutputDir()
    createTempDir()
    setFileNames()
    createPlaylists()
  end

  # clean temporary Dir (when finished)
  def cleanTempDir
    @file.removeDir(getTempDir())
  end

  # return the first directory (for the summary)
  def getDir(codec=nil)
    if codec != nil
      @dir[codec]
    else
      @dir.values[0]
    end
  end

  # return the full filename of the track (starting with 1) or image
  # track will be ignored if the user prefers an image rip
  def getFile(codec, track=nil)
    filename = @prefs.image ? @image[codec] : @files[codec][track]
    File.join(@dir[codec], filename)
  end

  # return the toc file of Cdrdao class // TODO this can't be; the dir is not yet created.
  def getTocFile
    File.join(getTempDir(), @filterFiles.filter("#{@md.artist} - #{@md.album}.toc"))
  end

  # return the full filename of the log
  def getLogFile(codec)
    File.join(@dir[codec], 'ripping.log')
  end

  # return the full filename of the cuesheet
  def getCueFile(codec)
    File.join(@dir[codec], @filterFiles.filter("#{@md.artist} - #{@md.album} (#{codec}).cue"))
  end

  # return the just ripped wave file
  def getTempFile(track=false, trial=nil)
    trial ||= 1
    File.join(getTempDir(), "#{@prefs.image ? "image" : "track_#{track}"}_#{trial}.wav")
  end

  #return the temporary dir
  def getTempDir
    File.join(File.dirname(@dir.values[0]), "temp_#{File.basename(@prefs.cdrom)}/")
  end

  # auto rename choice in directory already exist dialog
  def postfixDir
    postfix = 1
    @dir.values.each do |dir|
      while @file.directory?(dir + "\##{postfix}")
        postfix += 1
      end
    end
    @dir.keys.each{|key| @dir[key] = @dir[key] += "\##{postfix}"}
  end

  # remove existing dir choice in directory already exist dialog
  def overwriteDir
    @dir.values.each{|dir| @file.removeDir(dir)}
  end

  private

  def setVariables
    @dir = Hash.new    # store the dirs for each codec in @dir
    @files = Hash.new   # store the files each tracknumber + codec in @file.
    @image = Hash.new  # store the image file in @image
    @otherExtension = String.new
  end

  # choose which filescheme is relevant for the rip
  def setFileScheme
    if @prefs.image
      @fileScheme = @prefs.namingImage
    elsif @md.various?
      @fileScheme = @prefs.namingVarious
    else
      @fileScheme = @prefs.namingNormal
    end
    @fileScheme = File.expand_path(File.join(@prefs.basedir, @fileScheme))
  end

  # do a few clever checks on the filescheme
  def correctFilescheme()
    if !@md.various? && @fileScheme.include?('%va')
      @fileScheme.gsub!('%va', '')
      puts "Warning: '%va' in the filescheme for normal cd's makes no sense!"
      puts "This is automatically removed"
    end

    if @prefs.image
      if @fileScheme.include?('%n')
        @fileScheme.gsub!('%n', '')
        puts "Warning: '%n' in the filescheme for image rips makes no sense!"
        puts "This is automatically removed"
      end

      if @fileScheme.include?('%t')
        @fileScheme.gsub!('%t', '')
        puts "Warning: '%t' in the filescheme for image rips makes no sense!"
        puts "This is automatically removed"
      end
    end
  end

  # fill the @dir variable with the output dirs for each codec
  # no forward slashes allowed in dir names
  # artist and various artist always point at the album artist
  def setDirectoryForEachCodec
    artist = @md.artist.gsub('/', '')
    album = @md.album.gsub('/', '')

    @prefs.codecs.each do |codec|
      dir = File.dirname(@fileScheme)
      {'%a' => artist, '%b' => album, '%f' => codec, '%g' => @md.genre, '%y' => @md.year, '%va' => artist}.each do |key, value|
        value.nil? ? dir.gsub!(key, '') : dir.gsub!(key, value)
      end

      dir = File.join(dir, "CD #{sprintf("%02d", @md.discNumber)}") if @md.discNumber
      @dir[codec] = @filterDirs.filter(dir)
    end
  end

  # find the extension after the output (%o)
  def detectOtherCodecExtension
    if @prefs.other && @otherExtension.empty?
      match = /\B%o(\.\S+)/.match(@prefs.settingsOther)
      if ! match
        puts "Missing '.ext' after '%o' in settings."
        return
      end
      @otherExtension = match[1].downcase
      # Now clean the ext we just found
      # TODO: Is this needed? Seems to break filenames sometimes.
      del_range = (match.begin(1)...match.end(1))
      @prefs.settingsOther[del_range] = ""
    end
  end

  # create the output dirs
  def createOutputDir
    @dir.values.each{|dir| @file.createDir(dir)}
  end

  # create the temp dir
  def createTempDir
    @file.createDir(getTempDir())
  end

  # fill the @files variable, so we have for example @files['flac'][1]
  def setFileNames
    @prefs.codecs.each do |codec|
      if @prefs.image
        @image[codec] = giveFileName(codec)
      else
        @files[codec] = Hash.new
        (1..@disc.audiotracks).each{|track| @files[codec][track] = giveFileName(codec, track)}
      end
    end
    #if no hidden track is detected, getStartSector will return false
    setHiddenTrack() if @disc.getStartSector(0)
  end

  # give the filename for given codec and track
  def giveFileName(codec, track=0)
    file = File.basename(@fileScheme)

    # the artist should always refer to the artist that is valid for the track
    if (@prefs.image || !@md.various?)
      artist = @md.artist ; varArtist = ''
    else
      artist = @md.getVarArtist(track) ; varArtist = @md.artist
    end

    {'%a' => artist, '%b' => @md.album, '%f' => codec, '%g' => @md.genre,
    '%y' => @md.year, '%n' => sprintf("%02d", track), '%va' => varArtist,
    '%t' => @md.trackname(track)}.each do |key, value|
      if value.nil?
        file.gsub!(key, '')
      else
        file.gsub!(key, value)
      end
    end

    return @filterFiles.filter(file) + fileExtension(codec)
  end

  def fileExtension(codec)
    case codec
      when 'flac' then '.flac'
      when 'vorbis' then '.ogg'
      when 'mp3' then '.mp3'
      when 'wav' then '.wav'
      when 'nero' then '.m4a'
      when 'fraunhofer' then '.m4a'
      when 'wavpack' then '.wv'
      when 'opus' then '.opus'
      when 'other' then @otherExtension
    end
  end

  # Fill the metadata for the hidden track
  def setHiddenTrack
    @md.setTrackname(0, _("Hidden Track"))
    @md.setVarArtist(0, _("Unknown Artist")) if @md.various?
    @prefs.codecs.each{|codec| @files[codec][0] = giveFileName(codec, 0)} unless @prefs.image
  end

  # create Playlist for each codec
  def createPlaylists
    @prefs.codecs.each do |codec|
      if @prefs.playlist && !@prefs.image
        filename = File.join(@dir[codec], @filterFiles.filter("#{@md.artist} - #{@md.album} (#{codec}).m3u"))
        content = String.new
        @trackSelection.each{|track| content << @files[codec][track] + "\n"}
        @file.write(filename, content, false)
      end
    end
  end
end
