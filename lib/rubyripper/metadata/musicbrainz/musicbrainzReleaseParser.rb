#!/usr/bin/env ruby
#    Rubyripper - A secure ripper for Linux/BSD/OSX
#    Copyright (C) 2011  Ian Jacobi (pipian@pipian.com)
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

require 'rubyripper/metadata/data'
require 'rubyripper/preferences/main'
require 'rubyripper/system/network'

# This class can interpret MusicBrainz release XML
class MusicBrainzReleaseParser
attr_reader :status, :md

  WEB_SERVICE_BASE_URI = 'https://musicbrainz.org/ws/2/'
  VARIOUS_ARTISTS_ID = '89ad4ac3-39f7-470e-963a-56509c546377'
  MMD_NAMESPACE = 'http://musicbrainz.org/ns/mmd-2.0#'

  def initialize(md=nil, network=nil, prefs=nil)
    @md = md ? md : Metadata::Data.new()
    @network = network ? network : Network.new()
    @prefs = prefs ? prefs : Preferences::Main.instance
  end

  # setup actions to analyze the result
  # musicbrainzRelease = A REXML::Element object representing the release element
  def parse(musicbrainzRelease, musicbrainzDiscid, freedbDiscid)
    @musicbrainzRelease = musicbrainzRelease
    @musicbrainzDiscid = musicbrainzDiscid
    @freedbDiscid = freedbDiscid
    @network.startCgiConnection(WEB_SERVICE_BASE_URI)

    analyzeResult()
    @status = 'ok'
  end

private

  # MusicBrainz doesn't properly support genres, only folksonomy tags.
  def guessGenre
    # Taken from encode.rb
    possible_lame_tags = ['A CAPPELLA', 'ACID', 'ACID JAZZ', 'ACID PUNK', 'ACOUSTIC', 'ALTERNATIVE', 'ALT. ROCK', 'AMBIENT', 'ANIME', 'AVANTGARDE', \
'BALLAD', 'BASS', 'BEAT', 'BEBOB', 'BIG BAND', 'BLACK METAL', 'BLUEGRASS', 'BLUES', 'BOOTY BASS', 'BRITPOP', 'CABARET', 'CELTIC', 'CHAMBER MUSIC', 'CHANSON', \
'CHORUS', 'CHRISTIAN GANGSTA RAP', 'CHRISTIAN RAP', 'CHRISTIAN ROCK', 'CLASSICAL', 'CLASSIC ROCK', 'CLUB', 'CLUB-HOUSE', 'COMEDY', 'CONTEMPORARY CHRISTIAN', \
'COUNTRY', 'CROSSOVER', 'CULT', 'DANCE', 'DANCE HALL', 'DARKWAVE', 'DEATH METAL', 'DISCO', 'DREAM', 'DRUM & BASS', 'DRUM SOLO', 'DUET', 'EASY LISTENING', \
'ELECTRONIC', 'ETHNIC', 'EURODANCE', 'EURO-HOUSE', 'EURO-TECHNO', 'FAST-FUSION', 'FOLK', 'FOLKLORE', 'FOLK/ROCK', 'FREESTYLE', 'FUNK', 'FUSION', 'GAME', \
'GANGSTA RAP', 'GOA', 'GOSPEL', 'GOTHIC', 'GOTHIC ROCK', 'GRUNGE', 'HARDCORE', 'HARD ROCK', 'HEAVY METAL', 'HIP-HOP', 'HOUSE', 'HUMOUR', 'INDIE', 'INDUSTRIAL', \
'INSTRUMENTAL', 'INSTRUMENTAL POP', 'INSTRUMENTAL ROCK', 'JAZZ', 'JAZZ+FUNK', 'JPOP', 'JUNGLE', 'LATIN', 'LO-FI', 'MEDITATIVE', 'MERENGUE', 'METAL', 'MUSICAL', \
'NATIONAL FOLK', 'NATIVE AMERICAN', 'NEGERPUNK', 'NEW AGE', 'NEW WAVE', 'NOISE', 'OLDIES', 'OPERA', 'OTHER', 'POLKA', 'POLSK PUNK', 'POP', 'POP-FOLK', 'POP/FUNK', \
'PORN GROOVE', 'POWER BALLAD', 'PRANKS', 'PRIMUS', 'PROGRESSIVE ROCK', 'PSYCHEDELIC', 'PSYCHEDELIC ROCK', 'PUNK', 'PUNK ROCK', 'RAP', 'RAVE', 'R&B', 'REGGAE', \
'RETRO', 'REVIVAL', 'RHYTHMIC SOUL', 'ROCK', 'ROCK & ROLL', 'SALSA', 'SAMBA', 'SATIRE', 'SHOWTUNES', 'SKA', 'SLOW JAM', 'SLOW ROCK', 'SONATA', 'SOUL', 'SOUND CLIP', \
'SOUNDTRACK', 'SOUTHERN ROCK', 'SPACE', 'SPEECH', 'SWING', 'SYMPHONIC ROCK', 'SYMPHONY', 'SYNTHPOP', 'TANGO', 'TECHNO', 'TECHNO-INDUSTRIAL', 'TERROR', 'THRASH METAL', \
'TOP 40', 'TRAILER', 'TRANCE', 'TRIBAL', 'TRIP-HOP', 'VOCAL']
    tagMap = {
      'folk rock' => 'folk/rock',
      'indie folk' => 'indie',
      'indie pop' => 'indie',
      'alternative rock' => 'alternative',
      'pop rock' => 'rock',
      'rock and roll' => 'rock & roll'
    }
    tagMap.default_proc = proc do |hash, key|
      key
    end
    
    # Here's how we guess: at each level in the hierarchy of
    # release-group->artist (we pick artists arbitrarily for
    # a multi-artist disc) we look to see which tags, if any,
    # correspond with the set of possible LAME tags.  We then choose
    # the most popular of these matching tags.

    # NOTE: We ignore release tags for now, as the API appears broken(??)
    seenArtists = Set.new
    ['release-group', 'artist-credit/name-credit/artist', 'medium-list/medium/track-list/track/recording/artist-credit/name-credit/artist'].each do |xpath|
      objects = REXML::XPath::match(@musicbrainzRelease, xpath)
      objects.each do |object|
        # Retrieve the XML for the object.
        id = object.attributes['id']
        if not xpath.end_with?('artist') or not seenArtists.include?(id)
          if xpath.end_with?('artist')
            xpath = 'artist'
          end
          lookupPath = "#{xpath}/#{id}?inc=tags"
          objectDoc = REXML::Document.new(@network.get(File::expand_path(lookupPath, @network.path)))
          tags = REXML::XPath::match(objectDoc, "//tag").sort {|x,y| y.attributes['count'].to_i <=> x.attributes['count'].to_i or x.elements['name'].text <=> y.elements['name'].text}
          tags.collect! {|tag| tagMap[tag.elements['name'].text]}
          tags.each do |tag|
            if possible_lame_tags.include?(tag.upcase)
              tag = tag.split(/\b/).collect {|word| word.capitalize}
              return tag.join('')
            end
          end
          if xpath == 'artist'
            seenArtists << id
          end
        end
      end
    end
    nil
  end

  # tease out the useful data
  def analyzeResult
    @md.discid = @freedbDiscid
    @md.artist = String.new
    numArtists = 0
    variousArtists = false
    REXML::XPath::each(@musicbrainzRelease, 'artist-credit/name-credit', {'' => MMD_NAMESPACE}) do |credit|
      if credit.elements['name'] and credit.elements['name'].text
        @md.artist << REXML::XPath::first(credit, 'name').text
      elsif credit.elements['artist/name'] and credit.elements['artist/name'].text
        @md.artist << REXML::XPath::first(credit, 'artist/name').text
      end
      # ' / ' is default separator
      @md.artist << (credit.attributes['joinphrase'] || ' / ')
      numArtists += 1
      if credit.elements['artist'].attributes['id'] == VARIOUS_ARTISTS_ID
        variousArtists = true
      end
    end
    @md.artist = @md.artist[0..-4]
    if @musicbrainzRelease.elements['title'] and @musicbrainzRelease.elements['title'].text
      @md.album = @musicbrainzRelease.elements['title'].text
    end
    # For now, only allow the year.
    if @prefs.useEarliestDate and @musicbrainzRelease.elements['release-group/first-release-date'] and @musicbrainzRelease.elements['release-group/first-release-date'].text
      # inc=release-groups gives us the earliest date for free!
      @md.year = @musicbrainzRelease.elements['release-group/first-release-date'].text[0..3]
    elsif @musicbrainzRelease.elements['date'] and @musicbrainzRelease.elements['date'].text
      @md.year = @musicbrainzRelease.elements['date'].text[0..3]
    end
    # @md.genre is tricky to do at best (since all we have to go on
    # are tags of releases/groups/artists).
    # only assign the genre if found (otherwise @md will have a default value)
    bestGuessGenre = guessGenre
    @md.genre = bestGuessGenre if bestGuessGenre
    varArtist = {}
    # We only need tracks on the disc matching our discid.
    REXML::XPath::each(@musicbrainzRelease, "medium-list/medium/disc-list/disc[@id='#{@musicbrainzDiscid}']/../../track-list/track", {'' => MMD_NAMESPACE}) do |track|
      if track.elements['recording/title'] and track.elements['recording/title'].text
        @md.tracklist[track.elements['position'].text.to_i] = track.elements['recording/title'].text
      else
        @md.tracklist[track.elements['position'].text.to_i] = 'Unknown title'
      end
      # @md.varArtist depends on whether or not every track has the same artist (not Various Artists, because we also have to include splits)
      artist = String.new
      REXML::XPath::each(track, 'recording/artist-credit/name-credit', {'' => MMD_NAMESPACE}) do |credit|
        if credit.elements['name'] and credit.elements['name'].text
          artist << REXML::XPath::first(credit, 'name').text
        elsif credit.elements['artist/name'] and credit.elements['artist/name'].text
          artist << REXML::XPath::first(credit, 'artist/name').text
        end
        # ' / ' is default separator
        artist << (credit.attributes['joinphrase'] || ' / ')
      end
      artist = artist[0..-4] if artist.end_with?(' / ')
      varArtist[track.elements['position'].text.to_i] = artist
    end
    # extraDiscInfo => [Depends.  What do you want?]
    # Do we actually have a various artists disc?
    if varArtist.values.uniq.length > 1
      # Modulate our enthusiasm.  Just so we don't get tricked by
      # things like the 30th Anniversary Edition of Ziggy Stardust
      # (where the second disc will have two distinct artists, but the
      # album as a whole should still be credited to David Bowie)
      if numArtists > 1 or variousArtists
        @md.varArtist = varArtist
      end
    end
  end
end
