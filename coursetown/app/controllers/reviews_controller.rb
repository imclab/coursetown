# Knuth shuffle
class Array
  def shuffle
    a = Array.new(size)
    (0...size).each do |i|
      r = rand(i)
      a[i] = a[r]
      a[r] = self[i]
    end
    a
  end
end

class ReviewsController < ApplicationController
  protect_from_forgery :except => 'new_batch_from_transcript'

  def show
    @review = Review.find_by_id(params[:id],
      :include => {:offering => [:professors, :courses]})
    if @review.nil?
      render :status => 404
      return
    end
  end


  def course
    @course = Course.find( params[:id], :include => :reviews )
    @reviews = @course.reviews
    @avgs, counts = avg_reviews(@reviews)
    # TODO avg by prof too (& display who teaches it best)
  end


  def prof
    @prof = Professor.find( params[:id], :include => :reviews )
    @reviews = @prof.reviews
    @avgs, counts = avg_reviews(@reviews)
    # TODO avg by course too (& compare this prof in each course to others)
  end


  def offering
    @offering = Offering.find(params[:id],
      :include => [:professors, {:courses => {:offerings => [:reviews, :professors]}}])
    if @offering.nil? || @offering.professors.empty? || @offering.courses.empty?
      render :status => 404
      return
    end

    # description = specific description OR first existing course description
    if @offering.specific_desc
      @description = @offering.specific_desc
    elsif !(descs = @offering.courses.select(&:desc)).empty?
      puts "DESCS: #{descs}"
      @description = descs.first.desc
    else
      @description = nil
    end

    # if user has taken this course, get which offering(s) they took
    @schedule_offerings = nil
    if @current_user
      @schedule_offerings = Schedule.find_all_by_user_id_and_course_id(
        @current_user.id, @offering.courses.map(&:id),
        :include => :offering).map(&:offering)
      @in_wishlist = !Wishlist.find_by_user_id_and_course_id(
        @current_user.id, @offering.courses.map(&:id)).nil?
    end

    _year, _term = current_year_and_term
    puts "YEAR/TERM: #{_year} #{_term}"

    # get all offerings
    terms = Hash[%w{W S X F}.each_with_index.to_a]
    @prof_str = @offering.professors.map(&:name).sort.join(', ')
    all_offerings = @offering.other_offerings(:include => :reviews)
    # TODO filter out to just current & future offerings
    @other_offerings = all_offerings.select { |x| x != @offering }
    in_past = Proc.new do |o|
      o.year < _year || ((o.year == _year) && (terms[o.term] < terms[_term]))
    end
    @future_offerings = all_offerings.select { |o| !in_past.call(o) }
    @past_offerings = all_offerings.select { |o| in_past.call(o) }

    all_reviews = all_offerings.map(&:reviews).flatten.uniq
    # all_reviews = @offering.courses.map(&:reviews).flatten.uniq
    @reviews_by_profs = all_reviews.group_by do |review|
      review.professors.map(&:name).sort.join(", ")
    end

    # avg by prof
    @avgs_by_profs = {}
    @reviews_by_profs.each do |key, reviews|
      # TODO currently throwing away the counts...
      # show them on rollover?
      @avgs_by_profs[key], counts = avg_reviews(reviews)
    end

    # now review_buckets only contains reviews w/ other profs
    @reviews = @reviews_by_profs.delete( @prof_str )
    @avgs = @avgs_by_profs.delete( @prof_str )

    # get the overal average of this course
    # TODO should be a rollup for this to make it searchable!
    @course_avgs, counts = avg_reviews(all_reviews)

    # TODO find best profs teaching this course & see if
    #   (A) it conflicts w/ user's schedule
    #   (B) this is it
  end


  # form for creating new review
  def new
    # TODO populate with this user's grades (if pre-fetch = true?)
    # TODO check if the user has taken this class already during a different
    #   offering, and suggest they review the other time slot (but don't force
    #   it, because users can take some classes multiple times)

    offering_id = params[:id]
    force_login(request.fullpath) && return if @current_user.nil?

    sched = Schedule.find_by_user_id_and_offering_id(@current_user.id, offering_id,
      :include => :review)
    @review = sched.review if sched
    # @review = Review.find_by_user_id_and_offering_id(@current_user.id, params[:id])
    if @review.nil?
      @review = Review.new
      @review.offering = Offering.find(params[:id])
    end

    if @review.nil? || @review.offering.nil?
      render :status => 404
      return
      # TODO redirect user to a course selection page (maybe)
    end
  end


  # receives data from 'new' and creates review
  def create
    force_login(request.fullpath) && return if @current_user.nil?

    @review = params[:id] ? Review.find(params[:id]) : Review.new(params[:review])
    # TODO wrap everything after this point in one DB transaction?
    @review.save!
    schedule = Schedule.find_or_create_by_user_id_and_offering_id(@current_user.id, @review.offering.id)
    schedule.review = @review
    puts schedule.save ? "SAVE SUCCESSFUL" : "SAVE FAILURE!!!"
  end


  # TODO route & view
  # pulls grades from transcript, then prepopulates field with them
  def new_batch
    force_login(request.fullpath) && return if @current_user.nil?
    # @schedules = @current_user.schedules(:include => [:review, :course, {:offering => :courses}])
    # TODO this is a poor hack
    @schedules = Schedule.find_all_by_user_id(@current_user.id,
      :include => [:review, :course, {:offering => :courses}])
  end

  # returns JSON list of which reviews were successfully saved (by offering_id)
  def create_batch
    force_login(request.fullpath) && return if @current_user.nil?

    puts "PARAMS: #{params}"

    schedules = Hash.new
    # @current_user.schedules
    Schedule.find_all_by_user_id(@current_user.id, :include => :review) \
      .each { |s| schedules[s.offering_id] = s }

    successes = []
    params[:offerings].each do |offering_id, r_hash|
      r_hash[:offering_id] = offering_id

      # convert "reason = for_prof" to "for_prof = true"
      reasons = r_hash.delete(:reasons)
      next if !reasons
      r_hash[reasons] = true

      sched = schedules[offering_id]
      if sched && sched.review # then update
        # DON'T reset other reasons to false. if user writes a full review with
        # multiple reasons then edits their review in quick-review, don't
        # overwrite it, just add any new reasons (if they exist)
        success = sched.review.update_attributes(r_hash)
        if success
          sched.review = r
          sched.save
        end
      else # no review exists, so make a new one
        r = Review.new(r_hash)
        puts "REVIEW: #{r.attributes}"
        success = r.save

        # update schedules table to point to this review
        if success && sched
          sched.review = r
          sched.save # PANIC if this fails!
        elsif success # but no schedule, add a schedule
          sched = Schedule.new :user_id => @current_user.id,
            :offering_id => offering_id, :review_id => r.id
          sched.course = offering.courses.first
          sched.save # PANIC if this fails
        end
      end
      if success
        puts "SUCCESS: #{offering_id}"
        successes << offering_id
      else
        puts "FAILURE: #{offering_id}"
      end
    end

    render :json => successes
  end

  def update
    # TODO
  end


  def destroy
    review = Review.find_by_id(params[:id])

    if review.user != @current_user
      render :status => 401 # unauthorized
      return
    end
    review.destroy
  end

  # helper functions

  # note: dimensions have to be _attributes_ of the review object
  #   so :user doesn't work, but :user_id does.
  def avg_reviews(reviews, dimensions = [:course_rating, :prof_rating, :workload_rating, :grade])
    sum, count = {}, {}
    dimensions.each { |dim| sum[dim] = count[dim] = 0 }
    reviews.each do |review|
      dimensions.each do |dim|
        if review[dim]
          sum[dim] += review[dim]
          count[dim] += 1
        end
      end
    end
    # turn sum into avg
    sum.each_key { |key| count[key] != 0 ? sum[key] /= count[key] : 0 }
    return sum, count
  end

  def batch_start
  end

  # receive POST w/ full transcript data in it
  def new_batch_from_transcript
    force_login && return if @current_user.nil?

    # get existing schedule
    # build hash w/ keys of the form "COSC|5|2012|W"
    scheds = Hash.new
    @current_user.schedules.includes(:offering, :course).each do |sched|
      o, c = sched.offering, sched.course
      scheds["#{c.department}|#{c.number}|#{o.year}|#{o.term}"] = sched
    end

    ## PARSE
    results = parse_transcript(params[:transcript])

    ## IMPORT DATA

    unmatched, matchings = [], Hash.new
    results.each do |res|

      key = "#{res[:department]}|#{res[:number]}|#{res[:year]}|#{res[:term]}"
      # compare to existing schedule
      s = scheds[key]
      if s # they match
        # TODO update existing offering's metadata
        matchings[res] = s
      else
        unmatched << res
      end
    end

    # build "loose conditions"
    # e.g. anything in [COSC,MATH,ENGS] and [1,5,8,39], rather than smarter
    # filtering like 'COSC 5' or 'MATH 8'
    depts, numbers = Set.new, Set.new
    unmatched.each do |res|
      depts << res[:department]
      numbers << res[:number]
    end

    # grab everything meeting loose sets of conditions
    # TODO how do I actually pair these values in the query?
    courses = Course.
      find_all_by_department_and_number(depts.to_a, numbers.to_a,
        :include => :offerings)
    courses_hash = courses.group_by{|c| "#{c.department}|#{c.number}"}
    puts "#COURSE KEYS: #{courses_hash.each_key.to_a.join(' ')}"

    # group result offerings by course and check for direct matches
    unmatched.each do |res|
      course_key = "#{res[:department]}|#{res[:number]}"
      puts "KEY: #{course_key}"
      courses = courses_hash[course_key]
      puts "COURSES: #{courses.map(&:id).join(',')}" if !courses.nil?
      if courses.nil? || courses.empty?
        c = Course.new({:department => res[:department], :number => res[:number]})
        # TODO add "source => transcript" to course.
        # this is the LEAST credible source because anyone can provide false data
        puts "ERROR: couldn't save course #{c}" if !c.save
        courses = [c]
      end

      # find offerings (ideally just one) for this course & term/time
      offerings = courses.nil? ? [] : courses.map(&:offerings).flatten
      offerings.select! do |o|
        o.year == res[:year] && o.term == res[:term] && # times match
        ( o.median == res[:median] || # medians match (or one doesn't exist)
          o.median.nil? ||
          o.median == 0 ||
          res[:median].nil? ) &&
        ( o.enrollment == res[:enrollment] || # enrollments match (or one doesn't exist)
          o.enrollment.nil? ||
          o.enrollment == 0 ||
          res[:enrollment].nil? )
      end
      offerings.uniq!

      # if a single direct match, add to schedule & update offering
      if offerings.size == 1
        sched = Schedule.new(:offering_id => offerings.first.id,
          :user_id => @current_user.id, :course_id => courses.first.id)

        # puts "FAILED TO SAVE SCHED #{sched.attributes}" if !sched.save
        puts "SCHED: #{sched.attributes}"

        # update offering (median, enrollment)
        o = offerings.first
        o.median = res[:median] if !o.median || o.median == 0
        o.enrollment = res[:enrollment] if !o.enrollment || o.enrollment == 0
        # puts "FAILED TO UPDATE OFFERING #{o.attributes}" if !o.save
        puts "SAVING OFFERING: #{o.attributes}"
        matchings[res] = sched
      elsif offerings.size > 1
        # else if multiple direct matches / loose matches, offer them as options
        matchings[res] = [courses.first, offerings]
      else
        # else NO offerings exist, so force user to manually enter name(s)
        matchings[res] = [courses.first, nil]
      end
    end

    # if everything matches up to a schedule, render the new_batch page
    # (same thing but w/o prof. drop-downs)
    if matchings.all?{|res, s| s.instance_of? Schedule}
      @schedules = matchings.map{|res, s| s}
      render 'new_batch'
    end

    @results = results
    @matchings = matchings
  end

    # arg: transcript_html = full html page from [undergrad, undergrad]
  # returns: array of {year,term,department,number,enrollment,median,grade} objs
  def parse_transcript(escaped_transcript_html)
    html = escaped_transcript_html.gsub('&quot;','"').gsub('&apos;',"'")
    doc = Hpricot(html)
    rows = doc/'table.datadisplaytable tr'

    terms = {'winter' => 'W', 'fall' => 'F', 'summer' => 'X', 'spring' => 'S'}
    scraped_data = []
    current_term, current_year = 0,0
    rows.each do |row|

      children = row/'td'

      if children.empty?
        # term divider?
        if (labels = row/'th.ddlabel') && labels.size == 1 &&
            (label = labels.first) && label.attributes['colspan'].to_i == 12 &&
            (span = label/'span') && (contents = span.inner_html)

          term, mid, year = contents.split(' ')
          if term && mid && year && mid.downcase == 'term' &&
              (year = year.to_i) != 0 && (term = terms[term.downcase])

            current_term, current_year = term, year
          end
        end
      # if the row's all '.dddefault's, it's a course! scrape and record it.
      elsif children.size == 8 &&
          children.all?{|td| !(td.classes & ['dddefault', 'dddead']).empty? }

        h = Hash.new
        h[:year], h[:term] = current_year, current_term
        h[:department], h[:number], _, _, h[:enrollment], h[:median], h[:grade] =
          children.map {|td| td.classes.include?('dddead') ? nil : td.inner_html}
        scraped_data << h

        # gotcha: to be safe, strip leading zeros (SQL will handle them ok in
        # queries, but sometimes we manually do string comparisons
        h[:number] = h[:number].to_i if h[:number]
      end
    end

    puts "Just scraped #{scraped_data.size} courses off a transcript"
    # scraped_data.each{|d| puts "  * #{d[:year]} #{d[:term]} : #{d[:department]} #{d[:number]}"}
    scraped_data
  end
end
