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

require 'rubyripper/system/fileHash'
require 'rubyripper/calcPeakLevel'
require 'rubyripper/waveFile'
require 'rubyripper/system/dependency'
require 'rubyripper/system/execute'
require 'rubyripper/preferences/main'
require 'rubyripper/modules/audioCalculations'

# The SecureRip class is mainly responsible for:
# * Managing cdparanoia to fetch the files
# * Comparing the fetched files
# * Repairing the files if necessary

class SecureRip
  include AudioCalculations
  include GetText
  GetText.bindtextdomain("rubyripper")

  attr_writer :cancelled

  def initialize(trackSelection, disc, fileScheme, log, encoding, deps=nil, exec=nil, prefs=nil)
    @prefs = prefs ? prefs : Preferences::Main.instance
    @trackSelection = trackSelection
    @disc = disc
    @fileScheme = fileScheme
    @log = log
    @encoding = encoding
    @deps = deps ? deps : Dependency.instance()
    @exec = exec ? exec : Execute.new()
    @cancelled = false
    @reqMatchesAll = @prefs.reqMatchesAll # Matches needed for all chunks
    @reqMatchesErrors = @prefs.reqMatchesErrors # Matches needed for chunks that didn't match immediately
    @sizeExpected = 0
    @timeStarted = Time.now # needed for a time break after 30 minutes
    @crcs = []
    @correctedcrc = nil
    @digest = nil
    @rippersettingsBak = nil
  end

  def startTheRip()
    @log.updateRippingProgress() # Give a hint to the gui that ripping has started
    @prefs.image ? ripImage() : ripTracks()
    @deps.eject(@prefs.cdrom) if @prefs.eject
  end
  
  def ripImage
    puts "DEBUG: Ripping image" if @prefs.debug
    checkParanoiaSettings()
    ripTrack()
    restoreParanoiaSettings()
  end
    
  def ripTracks
    @trackSelection.each do |track|
      break if @cancelled == true
      puts "DEBUG: Ripping track #{track}" if @prefs.debug
      checkParanoiaSettings(track)
      ripTrack(track)
      restoreParanoiaSettings()
    end
  end

  # Due to a bug in cdparanoia the -Z setting has to be replaced for last track.
  # This is only needed when an offset is set. See issue nr. 13.
  def checkParanoiaSettings(track=nil)
    # if @prefs.rippersettings.include?('-Z') && @prefs.offset != 0
    #   if @prefs.image || track == @disc.audiotracks
    #     @rippersettingsBak = @prefs.rippersettings.dup()
    #     @prefs.rippersettings.gsub!(/-Z\s?/, '')
    #   end
    # end
  end

  # restore cdparanoia settings potentialy fixed up in checkParanoiaSettings
  def restoreParanoiaSettings
    if @rippersettingsBak != nil
      @prefs.rippersettings = @rippersettingsBak
      @rippersettingsBak = nil
    end
  end

  # rip one output file
  def ripTrack(track=nil)
    #reset next three variables for each rip
    @errors = Hash.new()
    @filesizes = Array.new
    @trial = 0

    # first check if there's enough size available in the output dir
    if sizeTest(track)
      if main(track)
        deEmphasize(track) unless @prefs.image
        @encoding.addTrack(track)
      else
        return false
      end #ready to encode
    end
  end

  # check if the track needs to be corrected
  # the de-emphasized file needs another name
  # when sox is finished move it back to the original name
  def deEmphasize(track)
    if @prefs.createCue && @prefs.preEmphasis == "sox" &&
      @disc.preEmph?(track) && @deps.installed?("sox")
      @exec.launch("sox #{@fileScheme.getTempFile(track, 1)} #{@fileScheme.getTempFile(track, 2)}")
      if @exec.status == 'ok'
        FileUtils.mv(@fileScheme.getTempFile(track, 2), @fileScheme.getTempFile(track, 1))
      else
        puts "sox failed somehow."
      end
    end
  end

  def sizeTest(track=nil)
    puts "DEBUG: Expected filesize for #{@prefs.image ? "image" : "track #{track}"} \
is #{@disc.getFileSize(track)} bytes." if @prefs.debug

    if @deps.installed?('df')
      output = @exec.launch("df \"#{@fileScheme.getDir()}\"", filename=false, noTranslations=true)
      freeDiskSpace = output[1].split()[3].to_i
      puts "DEBUG: Free disk space is #{freeDiskSpace} MB" if @prefs.debug
      if @disc.getFileSize(track) > freeDiskSpace*1000
        @log.error(_("Not enough disk space left! Rip aborted"))
        return false
      end
    end
    return true
  end

  def main(track=nil)
    @reqMatchesAll.times{if not doNewTrial(track) ; return false end} # The amount of matches all sectors should match
    analyzeFiles(track) #If there are differences, save them in the @errors hash
    status = _("Copy OK")

    while @errors.size > 0
      if @trial > @prefs.maxTries && @prefs.maxTries != 0
        # TODO: Attack these log entries
        #       "Irrecoverable sectors at the following times:"
        @log.listBadSectors(_("Irrecoverable sectors at the following times:"),
                            @errors)
        @log.mismatch(track, 0, @errors.keys, @disc.getFileSize(track), @disc.getLengthSector(track)) # zero means it is never solved.
        status = _("Copy finished")
        break # break out loop and continue using trial1
      end

      doNewTrial(track)
      break if @cancelled == true

      # update the erronous positions for the new trial
      readErrorPos(track)

      # if enough trials are done to possibly allow corrections
      # for example is trial = 3 and only 2 matches are required a match can happen
      correctErrorPos(track) if @trial > @reqMatchesErrors
      @correctedcrc = getCRC(track, 1)
    end

    @log.finishTrack(@peakLevel, @crcs, status, @correctedcrc)
    @log.copyMD5(@digest) # Get a MD5-digest for the logfile
    @log.updateRippingProgress(track)
    return true
  end

  def doNewTrial(track=nil)
    fileOk = false

    while (!@cancelled && !fileOk)
      @trial += 1
      rip(track)
      if fileCreated(track) && testFileSize(track)
        fileOk = true
      end
    end

    # when cancelled fileOk will still be false
    return fileOk
  end

  def fileCreated(track=nil) #check if cdparanoia outputs wav files (passing bad parameters?)
    if not File.exist?(@fileScheme.getTempFile(track, @trial))
      @log.update("error", _("Cdparanoia doesn't output WAVE files.\nCheck your settings please."))
      return false
    end
    return true
  end

  def testFileSize(track=nil) #check if wavfile is of correct size
    sizeDiff = @disc.getFileSize(track) - File.size(@fileScheme.getTempFile(track, @trial))

    # at the end the disc may differ 1 sector on some drives (2352 bytes)
    if sizeDiff == 0
      # expected size matches exactly
    elsif sizeDiff < 0
      puts "DEBUG: More sectors ripped than expected: #{sizeDiff / BYTES_AUDIO_FRAME} sector(s)" if @prefs.debug
    elsif @prefs.offset != 0 && (@prefs.image || track == @disc.audiotracks)
      # This should no longer happen.
      puts "DEBUG: The ripped file misses %s sectors." % [sizeDiff / BYTES_AUDIO_FRAME.to_f] if @prefs.debug
    elsif @cancelled == false
      if @prefs.debug
        puts "DEBUG: Some sectors are missing for track #{track} : #{sizeDiff} sector(s)"
        puts "DEBUG: File size should be: #{@disc.getFileSize(track)}"
      end

      #someone might get out of free diskspace meanwhile
      @cancelled = true if not sizeTest(track)

      File.delete(@fileScheme.getTempFile(track, @trial)) # Delete file with wrong filesize
      @trial -= 1 # reset the counter because the filesize is not right
      # TODO: Atack this log entry
      puts _("File size is not correct! Trying another time")
      return false
    end
    return true
  end

  # Start and close the first file comparisons
  def analyzeFiles(track=nil)
    start = Time.now()
    @crcs = []
    @reqMatchesAll.times{|time| @crcs << getCRC(track, time + 1)}
    compareSectors(track) unless filesEqual?(track)

    # Remove the files now we analyzed them. Differences are saved in memory.
    (@reqMatchesAll - 1).times{|time| File.delete(@fileScheme.getTempFile(track, time + 2))}

    if @errors.size == 0
      @log.allSectorsMatched()
    else
      track ||= 'image'
      @log.mismatch(track, @trial, @errors.keys, @disc.getFileSize(track), @disc.getLengthSector(track)) # report for later position analysis
      @log.listBadSectors(_("Sector mismatches at the following times, requiring extra trials:"),
                          @errors)
    end
  end

  # Compare if trial_1 matches trial_2, if trial_2 matches trial_3, and so on
  def filesEqual?(track=nil)
    comparesNeeded = @reqMatchesAll - 1
    trial = 1
    success = true

    while comparesNeeded > 0 && success == true
      file1 = @fileScheme.getTempFile(track, trial)
      file2 = @fileScheme.getTempFile(track, trial + 1)
      success = FileUtils.compare_file(file1, file2)
      trial += 1
      comparesNeeded -= 1
    end

    return success
  end

  # Compare the different sectors now we know the files are not equal
  # The first trial is used as a reference to compare the others
  # Bytes of erronous sectors are kept in memory for future comparisons
  def compareSectors(track=nil)
    files = Array.new
    (1..@reqMatchesAll).each{|trial| files << File.new(@fileScheme.getTempFile(track, trial), 'r')}

    comparesNeeded = @reqMatchesAll - 1
    (1..comparesNeeded).each do |trial|
      index = 0
      setFileIndex(files, index)

      while index + BYTES_WAV_CONTAINER < @disc.getFileSize(track)
        if sectorEqual?(files[0], files[trial]) && !@errors.key?(index)
          setFileIndex(files, index) # set back to read again
          @errors[index] = Array.new
          files.each{|file| @errors[index] << file.sysread(BYTES_AUDIO_FRAME)}
        end
        index += BYTES_AUDIO_FRAME
      end
    end

    files.each{|file| file.close}
  end

  def setFileIndex(filesArray, index)
    filesArray.each{|file| file.pos = index + BYTES_WAV_CONTAINER}
  end

  def sectorEqual?(file1, file2)
    file1.sysread(BYTES_AUDIO_FRAME) == file2.sysread(BYTES_AUDIO_FRAME)
  end

  # When required matches for mismatched sectors are bigger than there are
  # trials to be tested, readErrorPos() just reads the mismatched sectors
  # without analysing them.

  def readErrorPos(track=nil)
    file = File.new(@fileScheme.getTempFile(track, @trial), 'r')
    @errors.keys.sort.each do |start_chunk|
      file.pos = start_chunk + BYTES_WAV_CONTAINER
      @errors[start_chunk] << file.sysread(BYTES_AUDIO_FRAME)
    end
    file.close

    # Remove the file now we read it. Differences are saved in memory.
    File.delete(@fileScheme.getTempFile(track, @trial))

    # Give an update for the trials for later analysis
    @log.mismatch(track, @trial, @errors.keys, @disc.getFileSize(track), @disc.getLengthSector(track))
  end

  # Let the errors 'wave' out. For each sector that isn't unique across
  # different trials, try to find at least @reqMatchesErrors matches. If
  # indeed this amount of matches is found, correct the sector in the
  # reference file (trial 1).

  def correctErrorPos(track=nil)
    file1 = File.new(@fileScheme.getTempFile(track, 1), 'r+')
    minimumIndexDiff = @reqMatchesErrors - 1 # index 2 minus index 0 = 3 results

    # Sort the hash keys to prevent jumping forward and backwards in the file
    @errors.keys.sort.each do |key|
      raise "Wrong position (key) for @errors: #{key.class}" unless key.class == Integer
      raise "No array for @errors! (#{@errors[key].class})" unless @errors[key].class == Array
      @errors[key].sort!
      @errors[key].uniq.each do |result|
        raise "Invalid chunk data: #{result.class}" unless result.class == String
        if @errors[key].rindex(result) - @errors[key].index(result) >= minimumIndexDiff
          file1.pos = key + BYTES_WAV_CONTAINER
          file1.write(result)
          @errors.delete(key)
          break
        end
      end
    end

    file1.close

    #give an update of the amount of errors and trials
    if @errors.size == 0
      @log.correctedMismatches(@reqMatchesErrors)
    else
      @log.mismatch(track, @trial, @errors.keys, @disc.getFileSize(track), @disc.getLengthSector(track)) # report for later position analysis
    end
  end

  # add a timeout if a disc takes longer than 30 minutes to rip (this might save the hardware and the disc)
  def cooldownNeeded
    puts "DEBUG: Minutes ripping is #{(Time.now - @timeStarted) / 60}." if @prefs.debug

    if (((Time.now - @timeStarted) / 60) > 30 && @prefs.maxThreads != 0)
      puts _("Drive has been spinning for more than 30 minutes.")
      puts _("Taking a timeout of 2 minutes to protect the hardware.")
      sleep(120)
      @timeStarted = Time.now # reset time
    end
  end

  def rip(track=nil) # set cdparanoia command + parameters
    cooldownNeeded()

    timeStarted = Time.now

    @log.newTrack(track) if @trial == 1

    command = "cdparanoia"

    if @prefs.rippersettings.size != 0
      command += " #{@prefs.rippersettings}"
    end

    # What start/length do we expect?
    # Correct for whole frames if necessary (cdparanoia doesn't do this)
    start = @disc.getStartSector(track) + @prefs.offset / SAMPLES_A_FRAME
    length = @disc.getLengthSector(track) - 1

    if start < 0 and @prefs.offset < 0
      # Adjust the start so that we never read into the lead-in.
      start = 0
      noOffset = true
    elsif @prefs.offset > 0 && (@prefs.image || track == @disc.audiotracks)
      # Adjust the start so that we never read into the lead-out.
      start -= @prefs.offset / SAMPLES_A_FRAME
      noOffset = true
    end
    command += " [.#{start}]-[.#{length}]"

    # the ported cdparanoia for MacOS misses the -d option, default drive will be used.
    if @disc.multipleDriveSupport ; command += " -d #{@prefs.cdrom}" end

    if !noOffset
      command += " -O #{@prefs.offset}"
    end
    command += " \"#{@fileScheme.getTempFile(track, @trial)}\""

    @exec.launch(command) if @cancelled == false #Launch the cdparanoia command
    # TODO: Missing Filename
    timeElapsed = Time.now - timeStarted
    @log.finishTrial(@trial, timeElapsed, @disc.getLengthSector(track))
    
    if noOffset
      # Range includes either the start of a negative offset or the
      # end of a positive offset, and we need to trim and pad the
      # appropriate sides.
      file = WaveFile.new(@fileScheme.getTempFile(track, @trial))
      file.offset = @prefs.offset
      file.padMissingSamples = @prefs.padMissingSamples
      file.save!
    end
  end

  def getCRC(track=nil, trial)
    filename = @fileScheme.getTempFile(track, trial)

    hash = FileHash.new(filename)
    hash.calculate()

    @digest = hash.md5
    @crc32 = hash.crc32

    if trial == 1
      @calcPeakLevel ||= CalcPeakLevel.new()
      @peakLevel = @calcPeakLevel.getPeakLevel(filename)
    end

    return @crc32
  end
end
