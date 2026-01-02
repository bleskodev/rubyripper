#!/usr/bin/env ruby
#    Rubyripper - A secure ripper for Linux/BSD/OSX
#    Copyright (C) 2021  BleskoDev (bleskodev@ennumia.eu)
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
#

require 'rspec'
require 'rubyripper/preferences/cleanup'
require 'rubyripper/preferences/data'

describe Preferences::Cleanup do

  let(:prefs) { double('Preferences::Main').as_null_object }
  let(:pref_data) { Preferences::Data.new }
  let(:fileAndDir) { double('FileAndDir').as_null_object }
  let(:cleanup) { Preferences::Cleanup.new(fileAndDir, prefs) }

  context 'When settings contain references to freedb as selected metadata provider' do
    before(:each) do
      pref_data.site = ''
      pref_data.metadataProvider = ''
      expect(prefs).to receive(:data).and_return pref_data
    end

    it 'should replace freedb with gnudb as selected metadata provider' do
      pref_data.metadataProvider = 'freedb'
      cleanup.migrateFreedbToGnudb
      expect(pref_data.metadataProvider).to eq('gnudb')
    end

    it 'should not replace musicbrainz as selected metadata provider with gnudb' do
      pref_data.metadataProvider = 'musicbrainz'
      cleanup.migrateFreedbToGnudb
      expect(pref_data.metadataProvider).to eq('musicbrainz')
    end

    it 'should not replace none as selected metadata provider with gnudb' do
      pref_data.metadataProvider = 'none'
      cleanup.migrateFreedbToGnudb
      expect(pref_data.metadataProvider).to eq('none')
    end

    it 'should replace freedb site with gnudb site' do
      pref_data.site = 'http://freedb.freedb.org/~ccdb/ccdb.cgi'
      cleanup.migrateFreedbToGnudb
      expect(pref_data.site).to eq('http://gnudb.gnudb.org/~ccdb/ccdb.cgi')
    end

    it 'should NOT replace freedb site with gnudb site when it is not a real/full match' do
      pref_data.site = 'http://freedbtest.dyndns.org/~ccdb/ccdb.cgi'
      cleanup.migrateFreedbToGnudb
      expect(pref_data.site).to eq('http://freedbtest.dyndns.org/~ccdb/ccdb.cgi')
    end

  end
end
