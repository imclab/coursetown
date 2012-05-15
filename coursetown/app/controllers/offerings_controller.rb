class OfferingsController < ApplicationController

  # returns json, to be rendered via ajax
  def search_results
    logger.debug "==================================="
    queries = params[:queries]
    logger.debug queries
    logger.debug "==================================="

    @offerings = Offering.search_by_query(queries).uniq(&:id)

    if @offerings.blank?
      render :status => :not_found, :nothing => true
      return
    end

    respond_to do |format|
      format.json do
        # TODO: WTF. If I change this to 'map do' instead of 'map {' it BREAKS! HOW?!?!
        render :json => @offerings.map { |offering|
          hash = offering.attributes
          hash[:professors] = offering.professors.map(&:attributes)
          hash[:courses] = offering.courses.map(&:attributes)
          hash
        }
      end
      format.html do
        render :layout => false
      end
    end
  end

  def search_results_html
    @offerings = Offering.search_by_query(params[:queries])
  end

  def search
    respond_to do |format|
      format.html # search.html.erb
    end
  end

  # GET /offerings
  # GET /offerings.xml
  def index
    @offerings = Offering.all
    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @offerings }
    end
  end

  # GET /offerings/1
  # GET /offerings/1.xml
  def show
    @offering = Offering.find(params[:id])

    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml => @offering }
    end
  end

  # GET /offerings/new
  # GET /offerings/new.xml
  def new
    @offering = Offering.new

    respond_to do |format|
      format.html # new.html.erb
      format.xml  { render :xml => @offering }
    end
  end

  # GET /offerings/1/edit
  def edit
    @offering = Offering.find(params[:id])
  end

  # POST /offerings
  # POST /offerings.xml
  def create
    @offering = Offering.new(params[:offering])

    respond_to do |format|
      if @offering.save
        format.html { redirect_to(@offering, :notice => 'Offering was successfully created.') }
        format.xml  { render :xml => @offering, :status => :created, :location => @offering }
      else
        format.html { render :action => "new" }
        format.xml  { render :xml => @offering.errors, :status => :unprocessable_entity }
      end
    end
  end

  # PUT /offerings/1
  # PUT /offerings/1.xml
  def update
    @offering = Offering.find(params[:id])

    respond_to do |format|
      if @offering.update_attributes(params[:offering])
        format.html { redirect_to(@offering, :notice => 'Offering was successfully updated.') }
        format.xml  { head :ok }
      else
        format.html { render :action => "edit" }
        format.xml  { render :xml => @offering.errors, :status => :unprocessable_entity }
      end
    end
  end

  # DELETE /offerings/1
  # DELETE /offerings/1.xml
  def destroy
    @offering = Offering.find(params[:id])
    @offering.destroy

    respond_to do |format|
      format.html { redirect_to(offerings_url) }
      format.xml  { head :ok }
    end
  end
end
