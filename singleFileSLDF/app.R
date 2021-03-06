# Load packages:
# readr, readxl for data frame input
# leaflet for mapping
# dplyr for data wrangling
# Shiny for interactive apps
# deldir for voronoi cell calculations
# sp, rgdal for drawing polygons
# lubridate for easy handling of times and dates
# geosphere for haversine formula (calculate distance on sphere)

library(readr)
library(readxl)
library(leaflet)
library(dplyr)
library(shiny)
library(deldir)
library(sp)
library(rgdal)
library(lubridate)
library(geosphere)
library(raster)

# reading in data (project folder is working directory)
coord <- read_csv("../locationsToCoordinates.csv")
coord <- coord[order(coord$location),] # alphabetize location - coordinate dictionary
validLocations <- read_csv("../allAPs.csv") # aps <-> locations
dukeShape <- read_csv("../dukeShape.txt", col_names = FALSE)

numAPs <- validLocations %>% # number of APs per location
  group_by(location) %>% 
  summarise(num = n())

# splunkData <- read_csv("../eventData.csv")
# 
# # match aps to locations, merge for coordinates
# df <- splunkData[!is.na(splunkData$ap),] # remove observations with no ap
# 
# # Some aps are in splunk data with name, some with number - code below matches location using whichever is available
# nameMatch = which(validLocations$APname %in% df$ap) # find which aps have their name in the data
# numMatch = which(validLocations$APnum %in% df$ap) # find which aps have their number in the data
# validLocations$ap = c(NA) # new "flexible" column to store either name or number
# validLocations$ap[nameMatch] = validLocations$APname[nameMatch]
# validLocations$ap[numMatch] = validLocations$APnum[numMatch]
# 
# validLocations <- merge(coord, validLocations) # link coordinates to locations
# # use the new "flexible" ap variable to merge coordinates onto df
# df <- merge(df, validLocations, by = "ap") # this is the slow step
# write.csv(df, "../mergedData.csv")

df <- read_csv("../mergedData.csv")
df$`_time` <- force_tz(ymd_hms(df$`_time`), "EST")

# draw duke border
p = Polygon(dukeShape)
ps = Polygons(list(p),1)
sps = SpatialPolygons(list(ps))

# remove out-of-bounds locations
inBounds <- sapply(1:nrow(coord), function(x) {
  point.in.polygon(coord$long[x], coord$lat[x], unlist(dukeShape[,1]), unlist(dukeShape[,2]))
})
coord <- coord[inBounds == 1,]
coord <- merge.data.frame(coord,numAPs)
N = nrow(coord)
# calculating voronoi cells and converting to polygons to plot on map
z <- deldir(coord$long, coord$lat) # computes cells
# convert cell info to spatial data frame (polygons)
w <- tile.list(z)
polys <- vector(mode="list", length=length(w))
for (i in seq(along=polys)) {
  pcrds <- cbind(w[[i]]$x, w[[i]]$y)
  pcrds <- rbind(pcrds, pcrds[1,])
  polys[[i]] <- Polygons(list(Polygon(pcrds)), ID=as.character(i))
}
SP <- SpatialPolygons(polys)
SP <- intersect(SP, sps)
for(x in 1:nrow(coord)){
  SP@polygons[[x]]@ID <- as.character(x)
}
SPDF <- SpatialPolygonsDataFrame(SP, data=data.frame(x=coord[,2], y=coord[,3]))
# tag polygons with location name
SPDF@data$ID = coord$location
sapply(1:length(coord$location), function(x){
  SPDF@polygons[[x]]@ID <- coord$location[x]
  SPDF <<- SPDF
})

# Default coordinates that provide overview of entire campus
defLong <- -78.9272544 # default longitude
defLati <- 36.0042458 # default latitude
zm <- 15 # default zoom level

# Coordinates for West
wLati <- 36.0003456
wLong <- -78.939647
wzm <- 16

# Coordinates for East
eLati <- 36.0063344
eLong <- -78.9154213
ezm <- 17

# Coordinates for Central
cLati <- 36.0030883
cLong <- -78.9258819
czm <- 17


# Areas of polygons were calculated in original units (degrees). The code below approximates a sq. meter measure to a square degree (In Durham)
p1 <- c(defLong, defLati)
degScale = -3
p2 <- c(defLong + 10 ^ degScale, defLati)
p3 <- c(defLong, defLati + 10 ^ degScale)
# The Haversine formula calculates distances along a spherical surface.
areaConvert = distHaversine(p1, p2) * distHaversine(p1, p3) # = square meters per 10^degScale square degrees (in Durham)
areaConvert = areaConvert / 10^(2 * degScale) # square meters per square degree

# ------------------------------
# Mess with these numbers if you want.
timeSteps = c("1hr" = 60*60, "2hr" = 2*60*60, "4hr" = 4*60*60) # in seconds
# timeSteps = c("4 hr" = 4*60*60)
delay = 1800 # in milliseconds
# ------------------------------

start.time = (min(df$`_time`))
end.time = (max(df$`_time`))

# Filtering for all macaddrs in startingLocation within an hour of the start time
# to limit the size of the data set and prevent RStudio from crashing
# maybe can later be enabled with a radioButton or something
startingLocation <- "Perkins"
inte <- interval(start.time, start.time + 60 * 30)
macaddrInLoc <- df %>%
  filter(`_time` %within% inte) %>%
  filter(location.y == startingLocation)
macaddrInLoc <- unique(macaddrInLoc$macaddr)
df <- df %>% filter(macaddr %in% macaddrInLoc)

popDensityList <- list()
paletteList <- list()
macsToLocList <- list()
flowList <- list()

end.times <- rep(end.time, length(timeSteps))

for(i in 1){ # for(i in 1:length(timeSteps)){ # changed to run faster for testing purposes
  timeStep <- timeSteps[i]
  # Bin populations, calculate densities at each timestep, and cache for future plotting
  time.windowStart = start.time # time.window for selection
  populationDensities <- NULL
  #macsToLoc <- NULL
  someLines <- NULL
  
  while(end.time - timeStep * 12 > time.windowStart){ # while(end.time > time.windowStart){ # changed to run faster
    # Filter for time interval
    selInt = interval(time.windowStart, time.windowStart + timeStep)
    thisStep <- df %>%
      filter(`_time` %within% selInt)
    
    # Calculate Population Densities
    locationBinnedPop <- data.frame("location" = coord$location, "pop" = c(0))
    # For each location, count the number of unique devices (MAC addresses) that are present during the time time.window.
    locationBinnedPop$pop <- sapply(locationBinnedPop$location, function(x) {length(unique(thisStep$macaddr[thisStep$`location.y` == x]))})
    
    # Calculate a measure of people / (100 sq meters)
    densities_area <- sapply(1:N, function(x) {100 * locationBinnedPop$pop[x] / (SPDF@polygons[[x]]@area * areaConvert)})
    densities_aps  <- sapply(1:N, function(x) {locationBinnedPop$pop[x] / coord$num[x]})
    densities_both <- sapply(1:N, function(x) {locationBinnedPop$pop[x] / SPDF@polygons[[x]]@area / areaConvert / coord$num[x]})
    info <- c(densities_area, densities_aps, densities_both, locationBinnedPop$pop)
    type <- c(rep(1, N), rep(2, N), rep(3, N), rep(4, N))
    densitiesToSave <- data.frame("location" = locationBinnedPop$location,
                                  #"pop" = locationBinnedPop$pop,
                                  "ap_num" = coord$num, 
                                  "info" = info,
                                  "type" = type,
                                  "time.window" = c(time.windowStart))
    populationDensities <- rbind(populationDensities, densitiesToSave)
    
    # For each macaddr, keep track of where it currently is
    macs <- data.frame("macaddr" = thisStep$macaddr,
                       "location" = thisStep$location.y,
                       "long" = thisStep$long,
                       "lat" = thisStep$lat,
                       "time.window" = c(time.windowStart))
    macs <- macs[order(macs$macaddr), ]
    macsToLoc <- rbind(macsToLoc, macs)
    
    # keeping track of the lines of each macaddr's movement
    uniqMacs <- unique(macs$macaddr)
    uniqMacs <- as.character(uniqMacs)
    allLines <- NULL
    for(j in 1:length(uniqMacs)) {
      m <- macs %>% 
        filter(macaddr == uniqMacs[[j]])
      # there will be code that will skip locations if the prev and next
      # are extremely far away (e.g. East to West)
      # so, will need some way to keep track of prev and after locations
      # https://stackoverflow.com/questions/6955357/compare-adjacent-elements-of-the-same-vector-avoiding-loops
      # also need to think of circles when there isn't any movement 
      l <- Line(macs[3:4])
      l <- Lines(list(l), ID = uniqMacs[[j]])
      l <- c(l)
      allLines <- c(allLines, l)
    }
    SL <- SpatialLines(allLines)
    SLDF <- SpatialLinesDataFrame(SL, data = data.frame(macaddr = uniqMacs), match.ID = FALSE)
    SLDFDF <- data.frame("lines" = I(list(SLDF)),
                         "time.window" = c(time.windowStart))
    someLines <- rbind(someLines, SLDFDF)
    # list of three dataframes
    # each data frame has two things: 
    # SLDFs with their corresponding times
    
    
    end.times[i] <- time.windowStart
    time.windowStart = time.windowStart + timeStep
  }
  
  # setting up for chloropleth
  palette_area <- colorNumeric("YlOrRd", (populationDensities %>% filter(type == 1))$info)
  palette_aps  <- colorNumeric("YlOrRd", (populationDensities %>% filter(type == 2))$info)
  palette_both <- colorNumeric("YlOrRd", (populationDensities %>% filter(type == 3))$info)
  palette_raw  <- colorNumeric("YlOrRd", (populationDensities %>% filter(type == 4))$info)
  palette_area_log <- colorNumeric("YlOrRd", log((populationDensities %>% filter(type == 1))$info+1))
  palette_aps_log  <- colorNumeric("YlOrRd", log((populationDensities %>% filter(type == 2))$info+1))
  palette_both_log <- colorNumeric("YlOrRd", log((populationDensities %>% filter(type == 3))$info+1))
  palette_raw_log  <- colorNumeric("YlOrRd", log((populationDensities %>% filter(type == 4))$info+1))
  
  thisStepPaletteList <- list(palette_area, palette_aps, palette_both, palette_raw,
                              palette_area_log, palette_aps_log, palette_both_log, palette_raw_log)
  
  # Cache these guys away for later
  popDensityList[[i]] <- populationDensities
  paletteList[[i]] <- thisStepPaletteList
  macsToLocList[[i]] <- macsToLoc
  
  flowList[[i]] <- someLines
}

legendTitles <- c("Population Density (area)",
                  "Population Density (aps)", 
                  "Population Density (both)",
                  "Population (raw count)")

# app user interface
ui <- fluidPage(
  
  titlePanel("Duke Wireless Data"),
  
  sidebarLayout(
    sidebarPanel(
      # input a time to show temporally close records on map
      selectInput("timeStepSelection", "Time Step", choices = timeSteps, selected = timeSteps[1]),
      uiOutput("ui"),
      selectInput("select", "View:", choices = c("Population Density (area)" = 1, "Population Density (aps)" = 2, 
                                                 "Population Density (both)" = 3, "Population (raw)" = 4), selected = 1),
      radioButtons("focus", "Zoom View", choices = c("All", "East", "Central", "West"), selected = "All"),
      checkboxInput("log", "Log Scale", value = FALSE),
      checkboxInput("flow", "Track flow", value = FALSE),
      checkboxInput("track", "Track Single Macaddr", value = FALSE),
      conditionalPanel( # doesn't do anything, just as a reminder to implement
        condition = "input.track",
        textInput("mac", "Track", value = "Enter macaddr..."),
        actionButton("submit", "Submit")
      )
    ),
    
    
    
    mainPanel(
      leafletOutput("map", height = 850) # output the map, should check if height is ok with different screens
    )
  )
)

# app backend
server <- function(input, output, session) {
  
  # list of locations to be included
  include <- reactiveValues(poly = coord$location)
  
  # Seeing if a polygon was clicked and hiding/showing it as needed
  observeEvent(input$map_shape_click, {
    clickedLoc <- input$map_shape_click$'id'
    if(clickedLoc %in% include$poly) {
      include$poly <- include$poly[!include$poly %in% clickedLoc] # taking out of included polygons
    }
    else {
      include$poly <- c(include$poly, clickedLoc) # putting it back into included polygons
      include$poly <- sort(include$poly) # need to sort so that shapes drawn have correct id
    }
  })
  
  # Creates the initial map
  output$map <- renderLeaflet({
    leaflet() %>%
      setView("map", lng = defLong, lat = defLati, zoom = zm) %>% # sets initial map zoom & center
      addProviderTiles(providers$OpenStreetMap.BlackAndWhite) # adds Open Street Map info (otherwise just a gray box)
  })
  
  output$ui <- renderUI({
    # input a time to show temporally close records on map
    sliderInput("time", "Time", min = start.time, max = end.times[which(timeSteps == input$timeStepSelection)],
                value = start.time, animate = animationOptions(interval=delay),
                step = dseconds(input$timeStepSelection))
  })
  
  observe({
    #Filters for records within timeStep of the input time.
    if(is.null(input$time) | is.null(input$timeStepSelection)){
      return()
    }
    # populationDensities <- popDensityList[[which(timeSteps == input$timeStepSelection)]]
    # currMacs <- macsToLocList[[which(timeSteps == input$timeStepSelection)]]
    # flowLines <- flowList[[which(timeSteps == input$timeStepSelection)]]
    
    populationDensities <- popDensityList[[1]]
    currMacs <- macsToLocList[[1]]
    flowLines <- flowList[[1]]
    
    if(!any(populationDensities$time.window == input$time)){
      return()
    }
    
    if(input$flow | input$track) {
      # currMacs <- currMacs %>% 
      #   filter(time.window == input$time) %>% 
      #   filter(location %in% include$poly) 
      flowLines <- flowLines %>%
        filter(time.window == input$time)
    }
    
    thisStep <- populationDensities %>%
      filter(time.window == input$time) %>% 
      filter(location %in% include$poly) %>%
      filter(type == as.numeric(input$select))
    
    myPaletteList <- paletteList[[unname(which(timeSteps == input$timeStepSelection))]]
    myPalette <- myPaletteList[[as.numeric(input$select)]]
    if(input$log){
      thisStep$info <- log(thisStep$info + 1)
      myPalette <- myPaletteList[[as.numeric(input$select) + length(myPaletteList)/2]]
    }
    # Setting up for hover tooltips
    labels <- sprintf("<strong>%s</strong><br/ >%g APs<br/ >%g value",
                      thisStep$location, # location
                      thisStep$ap_num,
                      thisStep$info) %>% # plotted value
      lapply(htmltools::HTML)
    
    # Adds polygons and colors by population density.
    leafletProxy("map") %>%
      clearGroup("shapes") %>%
      clearGroup("severals") %>%
      clearControls() %>%
      addPolygons(data = SPDF[SPDF@data$ID %in% thisStep$location, ], # draws the included polygons
                  layerId = thisStep$location,
                  group = "shapes",
                  weight = 1,
                  color = 'black',
                  fillOpacity = .5,
                  fillColor = ~myPalette(thisStep$info),
                  label = labels)
    leafletProxy("map") %>%
      addPolygons(data = SPDF[!SPDF@data$ID %in% thisStep$location, ], # draws the unincluded polygons
                  layerId = coord$location[!coord$location %in% thisStep$location],
                  group = "shapes",
                  weight = 1.5,
                  color = 'white',
                  opacity = 0.2,
                  fillColor = ~myPalette(thisStep$info),
                  fillOpacity = 0)
    legendVals <- (populationDensities %>% filter(type == as.numeric(input$select)))$info
    if(input$log){
      legendVals <- log(1 + legendVals)
    }
    leafletProxy("map") %>%
      addLegend(pal = myPalette, 
                values = legendVals,
                position = "topright",
                title = legendTitles[as.numeric(input$select)])
    
    
    if(input$flow) {
      
      ##################
      # KNOWN BUGS:
      # app crashes when clicking on line -> input$map_shape_click detects click -> Warning: Error in if: argument is of length zero
      # cannot add labels as the app will crash -> processing overload as there are many overlaps
      
      # IDEAS/NEXT
      # Hide East to West lines <- def do this
      # Would like to make labels that show number of macaddrs moving
      # Cluster lines/make more obvious that more blue == more people
      #
      # Currently, it's kind of cool to look at which places have a lot of people coming and
      # going at a given time, but what it doesn't show is if people have been in that place
      # for a long time, and are now just leaving, or if they're just passing through.
      # If you hover over the place in raw popu mode, you can see how many people are currently
      # at that place, and so the bluer the "to" dot is on that location, the more people are
      # have known to have stopped at the location at that particular time. Sometimes
      # a good amount of people have also left that place from that time, although you see
      # a much bluer dot, and the amount of people from time A and B are about the same.
      # 
      # Notes
      # already tried addLayersControl
      # probably a better way to make the checkboxes
      ##################
      
      uniqMacs <- unique(currMacs$macaddr)
      uniqMacs <- as.character(uniqMacs)
      # looping through each macaddr to determine its movement
      for(i in 1:length(uniqMacs)) { 
        if(i == 20) { # to prevent stuff from crashing
          break
        }
        
        if(uniqMacs[[i]] %in% flowLines$lines[[1]]$macaddr) {
          
          index <- which(flowLines$lines[[1]]$macaddr == uniqMacs[[i]])[[1]]
          
          # drawing movement lines
          leafletProxy("map") %>% 
            addPolylines(data = flowLines$lines[[1]]@lines[[index]],
                         group = "severals",
                         weight = 2,
                         opacity = 0.3,
                         highlightOptions = highlightOptions( 
                           weight = 5,
                           color = 'black',
                           fillOpacity = 1,
                           bringToFront = TRUE)) 
        }
          
        
        
        # %>% 
        #   addCircles(lng = macs$long[1], # red is from
        #              lat = macs$lat[1],
        #              group = "severals",
        #              weight = 2,
        #              opacity = 0.3,
        #              color = 'red') %>% 
        #   addCircles(lng = macs$long[length(macs$long)], # blue is to
        #              lat = macs$lat[length(macs$lat)],
        #              group = "severals",
        #              weight = 2,
        #              opacity = 0.3,
        #              color = 'blue')
        
      } 
    }
    
    # Tracking just a single macaddr 
    if(input$track) {
      
      ##########
      # BUGS
      # Need to get rid of drawn lines when you deselect the checkbox
      # 
      # Eventually would like to not hardcode macaddr -- maybe have a randomize button?
      # Note to self: look at code and see how to do it better
      # Would like the future lines to disappear when going back in time
      ##########
      
      macs <- currMacs %>% 
        filter(macaddr == "5c:f7:e6:bb:39:51") %>% 
        filter(time.window <= input$time)
      
      macLocs <- macs %>% 
        group_by(location) %>%
        summarise(num = n())
      if(length(macLocs$location) == 1) { 
        leafletProxy("map") %>% 
          addCircles(lng = macs$long,
                     lat = macs$lat,
                     group = "singles",
                     radius = 3,
                     weight = 2,
                     opacity = 0.3)
        # drawing movement lines
      } else if(length(macs) != 0) { 
        leafletProxy("map") %>% 
          addPolylines(lng = macs$long, 
                       lat = macs$lat,
                       group = "singles",
                       weight = 5,
                       opacity = 0.5,
                       highlightOptions = highlightOptions(
                         weight = 8,
                         color = 'black',
                         fillOpacity = 1,
                         bringToFront = TRUE)) %>% 
          addCircles(lng = macs$long[1], # red is from
                     lat = macs$lat[1],
                     group = "singles",
                     weight = 2,
                     opacity = 0.3,
                     color = 'red') %>% 
          addCircles(lng = macs$long[length(macs$long)], # blue is to
                     lat = macs$lat[length(macs$lat)],
                     group = "singles",
                     weight = 2,
                     opacity = 0.3,
                     color = 'blue')
      }
    }
    
  })
  
  observe({
    if(input$focus == "West"){
      leafletProxy("map") %>% 
        flyTo(wLong, wLati, wzm)
    }
    if(input$focus == "East"){
      leafletProxy("map") %>% 
        flyTo(eLong, eLati, ezm)
    }
    if(input$focus == "Central"){
      leafletProxy("map") %>% 
        flyTo(cLong, cLati, czm)
    }
    if(input$focus == "All"){
      leafletProxy("map") %>% 
        flyTo(defLong, defLati, zm)
    }
  })
  
}

# Run the application 
shinyApp(ui = ui, server = server)
