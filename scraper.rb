#!/bin/env ruby
# encoding: utf-8

require 'scraperwiki'
require 'nokogiri'
require 'open-uri'
require 'colorize'
require 'rest-client'
require 'csv'
require 'combine_popolo_memberships'

require 'pry'
require 'open-uri/cached'
OpenURI::Cache.cache_path = '.cache'

@API_URL = 'http://api.parldata.eu/ge/parliament/%s'

def noko_q(endpoint, h)
  result = RestClient.get (@API_URL % endpoint), params: h
  warn result.request.url
  doc = Nokogiri::XML(result)
  doc.remove_namespaces!
  entries = doc.xpath('resource/resource')
  return entries if (np = doc.xpath('.//link[@rel="next"]/@href')).empty?
  return [entries, noko_q(endpoint, h.merge(page: np.text[/page=(\d+)/, 1]))].flatten
end

def earliest_date(*dates)
  dates.compact.reject(&:empty?).sort.first
end

def latest_date(*dates)
  dates.compact.reject(&:empty?).sort.last
end 

def terms
  @terms ||= noko_q('organizations', where: %Q[{"classification":"chamber"}] ).map do |chamber|
    { 
      id: chamber.xpath('.//identifiers[scheme[text()="parliament.ge"]]/identifier').text,
      identifier__parldata: chamber.xpath('.//id').text,
      name: chamber.xpath('.//name').text,
      start_date: chamber.xpath('.//founding_date').text,
      end_date: chamber.xpath('.//dissolution_date').text,
    }
  end
end

def person_data(person)
  official_id = person.xpath('.//identifiers[scheme[text()="parliament.ge"]]/identifier').text
  { 
    id: official_id,
    identifier__parliament_ge: official_id,
    identifier__parldata: person.xpath('id').text,
    name: person.xpath('name').text,
    sort_name: person.xpath('sort_name').text,
    family_name: person.xpath('family_name').text,
    given_name: person.xpath('given_name').text,
    honorific_prefix: person.xpath('honorific_prefix').text,
    birth_date: person.xpath('birth_date').text,
    death_date: person.xpath('death_date').text,
    gender: person.xpath('gender').text,
    email: person.xpath('./contact_details[type[text()="tel"]]/value').text,
    email: person.xpath('email').text,
    image: person.xpath('image').text,
    source: person.xpath('./sources[note[text()="ვებგვერდი"]]/url').text,
  }
end

def term_memberships(person)
  person.xpath('memberships[organization[classification[text()="chamber"]]]').map { |gm|
    id = gm.xpath('.//identifiers[scheme[text()="parliament.ge"]]/identifier').text
    term = terms.find { |t| t[:id] == id }
    {
      id: id,
      name: gm.xpath('organization/name').text,
      start_date: latest_date(gm.xpath('start_date').text, term[:start_date]),
      end_date: earliest_date(gm.xpath('end_date').text, term[:end_date]),
    }
  }
end

def group_memberships(person)
  person.xpath('memberships[organization[classification[text()="parliamentary group"]]]').map { |gm|
    {
      name: gm.xpath('organization/name').text,
      id: gm.xpath('id').text,
      start_date: latest_date(gm.xpath('organization/founding_date').text, gm.xpath('start_date').text),
      end_date: earliest_date(gm.xpath('organization/dissolution_date').text, gm.xpath('end_date').text),
    }
  }
end

# http://api.parldata.eu/ge/parliament/people?embed=[%22memberships.organization%22]
def people
  noko_q('people', { 
    max_results: 50,
    embed: '["memberships.organization"]',
  })
end


ScraperWiki.save_sqlite([:id], terms, 'terms')
people.each do |person|
  person.xpath('changes').each { |m| m.remove } # make eyeballing easier
  person_data = person_data(person)
  CombinePopoloMemberships.combine(term: term_memberships(person), faction_id: group_memberships(person)).each do |mem|
    data = person_data.merge(mem).reject { |k, v| v.to_s.empty? }
    ScraperWiki.save_sqlite([:id, :term, :faction_id, :start_date], data)
  end
end

