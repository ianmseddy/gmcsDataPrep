
# Everything in this file gets sourced during simInit, and all functions and objects
# are put into the simList. To use objects, use sim$xxx, and are thus globally available
# to all modules. Functions can be used without sim$ as they are namespaced, like functions
# in R packages. If exact location is required, functions will be: sim$<moduleName>$FunctionName
defineModule(sim, list(
  name = "gmcsDataPrep",
  description = NA, #"insert module description here",
  keywords = NA, # c("insert key words here"),
  authors = c(person(c("Ian", "MS"), "Eddy", email = "ian.eddy@canada.ca", role = c("aut", "cre"))),
  childModules = character(0),
  version = list(SpaDES.core = "0.2.4", gmcsDataPrep = "0.0.1"),
  spatialExtent = raster::extent(rep(NA_real_, 4)),
  timeframe = as.POSIXlt(c(NA, NA)),
  timeunit = "year",
  citation = list("citation.bib"),
  documentation = list("README.txt", "gmcsDataPrep.Rmd"),
  reqdPkgs = list('data.table', 'sf', 'sp', 'raster', 'nlme', 'crayon', 'glmm',
                  "PredictiveEcology/LandR@development", "MASS", "gamlss", "LandR.CS", 'PredictiveEcology/pemisc@development'),
  parameters = rbind(
    #defineParameter("paramName", "paramClass", value, min, max, "parameter description"),
    defineParameter(".useCache", "logical", FALSE, NA, NA,
                    desc = "Should this entire module be run with caching activated?
                    This is generally intended for data-type modules, where stochasticity and time are not relevant"),
    defineParameter("PSPperiod", "numeric", c(1958, 2011), NA, NA,
                    desc = "The years by which to compute climate normals and subset sampling plot data.
                    Must be a vector of at least length 2"),
    defineParameter("minDBH", "numeric", 10, 0, NA,
                    desc = "The minimum DBH allowed. Each province uses different criteria for monitoring trees,
                    so absence of entries < min(DBH) does not equate to absence of trees."),
    defineParameter("useHeight", "logical", FALSE, NA, NA, desc = "Should height be used to calculate biomass (in addition to DBH).
                    Don't use if studyAreaPSP includes Alberta"),
    defineParameter("biomassModel", "character", "Lambert2005", NA, NA, desc =  "The model used to calculate biomass from DBH.
                    Can be either 'Lambert2005' or 'Ung2008'"),
    defineParameter("cacheClimateRas", "logical", TRUE, NA, NA, desc = "should reprojection of climate rasters be cached every year?
    This will result in potentially > 100 rasters being cached"),
    defineParameter("growthModel", class = "call", quote(glmmPQL(growth ~ logAge*(ATA + CMI) + ATA*CMI, random = ~1 | OrigPlotID1,
                                    weights = scale(PSPmodelData$plotSize^0.5 * PSPmodelData$periodLength, center = FALSE),
                                    data = PSPmodelData, family = "Gamma"(link='log'))),
                 NA, NA, desc = "Quoted model used to predict growth in PSP data as a function of logAge, CMI, ATA, and
                 their interactions, with PlotID as a random effect"),
    defineParameter("mortalityModel", class = "call",
                    quote(gamlss(formula = mortality ~ logAge * (ATA + CMI) + ATA * CMI +
                                   LandR.CS::own(random = ~ 1|OrigPlotID1, weights = varFunc(~plotSize^0.5 * periodLength)),
                                 sigma.formula = ~logAge + ATA,  nu.formula = ~logAge, family = ZAIG, data = PSPmodelData)),
                    NA, NA, desc = paste("Quoted model used to predict mortality in PSP data as a function of logAge, CMI, ATA, and",
                 "their interactions, with PlotID as a random effect. Defaults to zero-inflated inverse gaussian glm that requires",
                    "custom LandR.CS predict function to predict...for now")),
    defineParameter("GCM", "character", "CCSM4_RCP4.5", NA, NA,
                    desc = paste("if using default climate data, the global climate model and rcp scenario to use.",
                                 "Defaults to CanESM2_RCP4.5. but other available options include CanESM2_RCP4.5 and CCSM4_RCP8.5.",
                                 "These were all generated using a 3 Arc-Minute DEM covering forested ecoregions of Canada.",
                                 "If ATA and CMI are supplied by the user, this parameter is ignored.")),
    defineParameter("yearOfFirstClimateImpact", 'numeric', 2011, NA, NA,
                    desc = paste("the first year for which to calculate climate impacts. For years preceeding this parameter"))
  ),
  inputObjects = bindrows(
    #expectsInput("objectName", "objectClass", "input object description", sourceURL, ...),
    expectsInput(objectName = "ATAstack", objectClass = "RasterStack",
                 desc = paste("annual projected mean annual temperature anomalies, units stored as tenth of a degree"),
                 sourceURL = NA),
    expectsInput(objectName = "CMIstack", objectClass = "RasterStack",
                 desc = "annual projected mean climate moisture deficit",
                 sourceURL = NA),
    expectsInput(objectName = "CMInormal", objectClass = "RasterLayer",
                 desc = "Climate Moisture Index Normals from 1950-2010"),
    expectsInput(objectName = 'PSPmeasure', objectClass = 'data.table',
                 desc = "PSP data for individual measures", sourceURL = NA),
    expectsInput(objectName = 'PSPplot', objectClass = 'data.table',
                 desc = "PSP data for each plot", sourceURL = NA),
    expectsInput(objectName = 'PSPgis', objectClass = 'data.table',
                 desc = "PSP plot data as sf object", sourceURL = NA),
    expectsInput(objectName = "PSPclimData", objectClass = "data.table",
                 desc = paste("climate data for each PSP from ClimateNA, in the native format returned by ClimateNA with csv",
                              "Temp is represented as degrees, not tenth of degrees as with the raster data"),
                 sourceURL = "https://drive.google.com/file/d/1wFRcMc4iS84FrsWCT414EZncA_1Uo7Qi/view?usp=sharing"),
    expectsInput(objectName = "rasterToMatch", objectClass = "RasterLayer",
                 desc = "template raster for ATA and CMI"),
    expectsInput(objectName = "studyArea", objectClass = "SpatialPolygonsDataFrame",
                 desc = "this area will be used to crop climate rasters", sourceURL = NA),
    expectsInput(objectName = 'studyAreaPSP', objectClass = 'SpatialPolygonsDataFrame',
                 desc = "this area will be used to subset PSP plots before building the statistical model. Currently PSP datasets with repeat measures exist only for Saskatchewan, Alberta, and Boreal British Columbia",
                 sourceURL = NA)
  ),
  outputObjects = bindrows(
    #createsOutput("objectName", "objectClass", "output object description", ...),
    createsOutput(objectName = "PSPmodelData", objectClass = "data.table",
                  desc = "PSP growth mortality calculations"),
    createsOutput(objectName = 'CMI', objectClass = "RasterLayer",
                  desc = "climate moisture deficit at time(sim), resampled using rasterToMatch"),
    createsOutput(objectName = 'ATA', objectClass = "RasterLayer",
                  desc = "annual temperature anomaly, resampled using rasterToMatch"),
    createsOutput(objectName = "gcsModel", objectClass = "ModelObject?",
                  desc = "growth mixed effect model with normalized log(age), ATA, and CMI as predictors"),
    createsOutput(objectName = "mcsModel", objectClass = "ModelObject?",
                  desc = "mortality mixed effect model with normalized log(age), ATA, and CMI as predictors")
    )
))

## event types
#   - type `init` is required for initialization

doEvent.gmcsDataPrep = function(sim, eventTime, eventType) {
  switch(
    eventType,
    init = {
      # do stuff for this event
      sim <- Init(sim)
      sim <- scheduleEvent(sim, start(sim), eventType = "prepRasters", eventPriority = 1)
      sim <- scheduleEvent(sim, end(sim), eventType = "scrubGlobalEnv", eventPriority = 9)
    },

    prepRasters = {
      sim$ATA <- resampleStacks(stack = sim$ATAstack, time = time(sim), isATA = TRUE,
                                studyArea = sim$studyArea, rtm = sim$rasterToMatch,
                                cacheClimateRas = P(sim)$cacheClimateRas,
                                firstYear = P(sim)$yearOfFirstClimateImpact)
      if (is.null(sim$ATA) & time(sim) < P(sim)$yearOfFirstClimateImpact) {
        sim$ATA <- sim$rasterToMatch #replace with a raster with no climate anomaly
        sim$ATA[!is.na(sim$ATA)] <- 0
      }

      sim$CMI <- resampleStacks(stack = sim$CMIstack, time = time(sim),
                                studyArea = sim$studyArea, rtm = sim$rasterToMatch,
                                cacheClimateRas = P(sim)$cacheClimateRas,
                                firstYear = P(sim)$yearOfFirstClimateImpact)
      if (is.null(sim$CMI) & time(sim) < P(sim)$yearOfFirstClimateImpact) {
        sim$CMI <- sim$CMInormal #replace with a raster with no climate anomaly
      }

      sim <- scheduleEvent(sim, time(sim) + 1, eventType = "prepRasters", eventPriority = 1)
    },

    scrubGlobalEnv = {
      on.exit(rm(PSPmodelData, envir = globalenv()), add = TRUE)
    },

    warning(paste("Undefined event type: '", current(sim)[1, "eventType", with = FALSE],
                  "' in module '", current(sim)[1, "moduleName", with = FALSE], "'", sep = ""))
  )
  return(invisible(sim))
}

## event functions
#   - keep event functions short and clean, modularize by calling subroutines from section below.

### template initialization
Init <- function(sim) {

  #stupid-catch
  if (length(P(sim)$PSPperiod) < 2) {
    stop("Please supply P(sim)$PSPperiod of length 2 or greater")
  }

  if (any(is.null(sim$PSPmeasure), is.null(sim$PSPplot), is.null(sim$PSPgis))) {
    stop("The PSP objects are being supplied incorrectly. Please review loadOrder argument in simInit")
  }

  sim$PSPmodelData <- Cache(prepModelData, studyAreaPSP = sim$studyAreaPSP,
                            PSPgis = sim$PSPgis,
                            PSPmeasure = sim$PSPmeasure,
                            PSPplot = sim$PSPplot,
                            PSPclimData = sim$PSPclimData,
                            useHeight = P(sim)$useHeight,
                            biomassModel = P(sim)$biomassModel,
                            PSPperiod = P(sim)$PSPperiod,
                            minDBH = P(sim)$minDBH,
                            useCache = P(sim)$.useCache,
                            userTags = c("gmcsDataPrep", "prepModelData"))

  sim$gcsModel <- gmcsModelBuild(PSPmodelData = sim$PSPmodelData,
                                 model = P(sim)$growthModel,
                                 type = "growth")
  sim$mcsModel <- gmcsModelBuild(PSPmodelData = sim$PSPmodelData,
                                 model = P(sim)$mortalityModel,
                                 type = "mortality")

  return(invisible(sim))
}

prepModelData <- function(studyAreaPSP, PSPgis, PSPmeasure, PSPplot,
                          PSPclimData, useHeight, biomassModel,
                          PSPperiod, minDBH) {

  #first remove trees with 9999 as TreeNumber
  PSPmeasure <- PSPmeasure[TreeNumber != '9999']

  #Crop points to studyAreaPSP
  if (!is.null(studyAreaPSP)) {
    tempSA <- spTransform(x = studyAreaPSP, CRSobj = crs(PSPgis)) %>%
      st_as_sf(.)
    message(yellow("Filtering PSPs to study Area..."))
    PSP_sa <- PSPgis[tempSA,] %>% #Find how to cache this. '[' did not work
      setkey(., OrigPlotID1)
    message(yellow(paste0("There are "), nrow(PSP_sa), " PSPs in your study area"))
  } else {
    PSP_sa <- PSPgis
  }
  #Restrict climate variables to only thosee of interest.. should be param
  #Calculate the derived variable CMI - previously calculated in input objects
  PSPclimData[, "CMI" := MAP - Eref]
  PSPclimData <- PSPclimData[,.(OrigPlotID1, Year, CMI, MAT)]

  #Filter other PSP datasets to those in study Area
  PSPmeasure <- PSPmeasure[OrigPlotID1 %in% PSP_sa$OrigPlotID1,]
  PSPplot <- PSPplot[OrigPlotID1 %in% PSP_sa$OrigPlotID1,]
  PSPclimData <- PSPclimData[OrigPlotID1 %in% PSP_sa$OrigPlotID1,]


  #might as well drop species with no biomass match

  #length(PSPclimData)/length(PSP_sa) should always yield a whole number.
  #Filter data by study period
  message(yellow("Filtering by study period..."))
  PSPmeasure <- PSPmeasure[MeasureYear > min(PSPperiod) &
                             MeasureYear < max(PSPperiod),]
  PSPplot <- PSPplot[MeasureYear > min(PSPperiod) &
                       MeasureYear < max(PSPperiod),]
  PSPclimData[Year > min(PSPperiod) & Year < max(PSPperiod),]

  #Join data (should be small enough by now)
  PSPmeasure <- PSPmeasure[PSPplot, on = c('MeasureID', 'OrigPlotID1', 'MeasureYear')]
  PSPmeasure[, c('Longitude', 'Latitude', 'Easting', 'Northing', 'Zone'):= NULL]


  #Restrict to trees > minDBH
  PSPmeasure <- PSPmeasure[DBH >= minDBH,]
  # PSPplot <- PSPplot[MeasureID %in% PSPmeasure$MeasureID] This will be repeated below

  #Filter by > 30 trees at first measurement (P) to ensure forest.
  message(yellow("Filtering by min. 30 trees in earliest measurement"))
  forestPlots <- PSPmeasure[MeasureYear == baseYear, .(measures = .N), OrigPlotID1] %>%
    .[measures >= 30,]
  PSPmeasure <- PSPmeasure[OrigPlotID1 %in% forestPlots$OrigPlotID1,]
  PSPplot <- PSPplot[OrigPlotID1 %in% PSPmeasure$OrigPlotID1,]
  repeats <- PSPplot[, .(measures = .N), by = OrigPlotID1]
  message(yellow(paste0("There are "), nrow(repeats), " PSPs with min. 30 trees at earliest measurement"))


  #subset by biomass, because some plots have no species that can be estimated
 #These will be counted in the 30 trees requirement, but may result in a plot of NA biomass if repeat measures = 2+
  tempOut <- biomassCalculation(species = PSPmeasure$newSpeciesName,
                                DBH = PSPmeasure$DBH,
                                height = PSPmeasure$Height,
                                includeHeight = useHeight,
                                equationSource = biomassModel)
  message(yellow("No biomass estimate possible for these species: "))
  print(tempOut$missedSpecies)
  PSPmeasure$biomass <- tempOut$biomass


  #Filter by 3+ repeat measures - must be last filter criteria.
  #Some plots share ID but have different trees so simple count of plots insufficient to find repeat measures
  #Reduce PSPmeasure to MeasureID, PlotID1, PlotID2, MeasureYear, remove duplicates
  # then find repeat measures of MeasureYear, match back to MeasureID in both PSPplot and PSPmeasure.
  message(yellow("Filtering by at least 3 repeat measures per plot"))
  repeats <- PSPmeasure[, .(MeasureID, OrigPlotID1, MeasureYear)] %>%
    .[!duplicated(.)] %>%
    .[, .('repeatMeasures' = .N), by = .(OrigPlotID1)] %>%
    .[repeatMeasures > 2]
  setkey(repeats, OrigPlotID1)
  setkey(PSPmeasure, OrigPlotID1)
  PSPmeasure <- PSPmeasure[repeats]
  PSPplot <- PSPplot[MeasureID %in% PSPmeasure$MeasureID] #this ensures all plots have biomass/repeat measures

  message(yellow(paste0("There are "), nrow(repeats), " PSPs with min. 3 repeat measures"))

  climate <- PSPclimData[OrigPlotID1 %in% PSPmeasure$OrigPlotID1, .("CMI" = mean(CMI), "MAT" = mean(MAT)), OrigPlotID1]
  #not all PSP plots exist in PSPclimData - this must be fixed - July 2020 IE
  PSPmeasure <- PSPmeasure[OrigPlotID1 %in% climate$OrigPlotID1,]
  PSPplot <- PSPplot[climate, on = "OrigPlotID1"]

  if (any(nrow(PSPclimData) == 0, nrow(PSPmeasure) == 0, nrow(PSPgis) == 0)) {
    stop('all existing PSP data has been filtered.Try adjusting parameters')
  }

  TrueUniques <- PSPmeasure[, .N, .(OrigPlotID1)]

  pSppChange <- lapply(1:nrow(TrueUniques), rows = TrueUniques,
                       FUN = sumPeriod, m = PSPmeasure, p = PSPplot, clim = PSPclimData)
  PSPmodelData <- rbindlist(pSppChange)
  PSPmodelData$species <- factor(PSPmodelData$species)
  PSPmodelData$sppLong <- factor(PSPmodelData$sppLong)

  #Standardize by plotSize and change units from kg/ha to g/m2. = *1000 g/kg / 10000 m2/ha
  PSPmodelData <- PSPmodelData[, growth_gm2 := growth/plotSize/10] %>%
    .[, mortality_gm2 := mortality/plotSize/10] %>%
    .[, netBiomass_gm2 := netBiomass/plotSize/10]
  #26/02/2019 after discussion we decided not to include species in model.
  # Decided to parameterize inclusion of ATA or year. ATA is better for projecting, but year is canonical
  # Sum species-specific mortality, growth, and net biomass by plot and year
  PSPmodelData <- PSPmodelData[, .("growth" = sum(growth_gm2), "mortality" = sum(mortality_gm2),
                                   "netBiomass" = sum(netBiomass_gm2), 'CMI' = mean(CMI), 'CMIA' = mean(CMIA),
                                   'AT' = mean(AT), "ATA" = mean(ATA), 'standAge' = mean(standAge),
                                   'logAge' = mean(logAge), "periodLength" = mean(periodLength),
                                   'year' = mean(year), 'plotSize' = mean(plotSize)), by = c("OrigPlotID1", "period")]

  return(PSPmodelData)
}

gmcsModelBuild <- function(PSPmodelData, model, type) {

  if (type == 'growth') {

    gmcsModel <- Cache(eval, model, envir = environment(), userTags = c("gmcsDataPrep", "growthModel"))

  } else {
    assign(x = 'PSPmodelData', value = PSPmodelData, envir = globalenv())
    #This is an obnoxious fix to an mgcv problem, once it is resolved, remember to remove scrubGlobalEnv event
    gmcsModel <- Cache(foo, mod = model, dat = PSPmodelData)
  }

  # for reference, Yong's original multivariate model (year substituted for ATA)
  # gmcsModel <- lme(cbind(netBiomass, growth, mortality) ~ logAge + CMI + ATA + logAge:CMI + CMI:ATA + ATA
  #logAge, random = ~1 | OrigPlotID1, weights = varFunc(~plotSize^0.5 * periodLength), data = PSPmodelData)

  return(gmcsModel)
}

#This function exists to cache the converged model
foo <- function(mod, dat) {

  gmcsModel <- Cache(eval, mod, envir = environment(), userTags = c("gmcsDataPrep", "mortModel"))
  defaultModel <- quote(gamlss(formula = mortality ~ logAge * (ATA + CMI) + ATA * CMI +
                                 LandR.CS::own(random = ~ 1|OrigPlotID1, weights = varFunc(~plotSize^0.5 * periodLength)),
                               sigma.formula = ~logAge + ATA,
                               nu.formula = ~logAge,
                               family = ZAIG, data = dat))

  #to ensure convergence, test whether quoted mod is the default first. How to ensure convergence for user-passed models?
  if (mod == defaultModel){
    i <- 1
    while (!gmcsModel$converged & i <= 2) {
      i <- i+1
      gmcsModel <- refit(gmcsModel)
    }
  }
  return(gmcsModel)
}

resampleStacks <- function(stack, time, isATA = FALSE, studyArea, rtm, cacheClimateRas, firstYear) {
  # Restructured to test time for number of characters (entering time as XX or YYYY)
  if (nchar(time) <= 3){
    time <- time + 2001 #2001 is purely arbirtary for Tati's sake due to kNN - boo relative years
    message(paste0("Time entered is < 1900. Temporarily converting your current time as ",
                   crayon::yellow("time + 2001"),
                   "(year of Knn data collection). The current time is now ", time, ".",
                   " \nIf the simulation is set up for more than 1000 years,\nplease provide the start and end time as ",
                   crayon::yellow("YYYY")))
  }

  if (time < firstYear) {
    return(NULL) #don't return climate data - the object will be modified to the reference conditions later
  }

  currentRas <- grep(pattern = time, x = names(stack))

  if (length(currentRas) > 0) {
    #if useCache is False, this generates 6 messages a year.

    if(!compareRaster(stack[[currentRas]], rtm, stopiffalse = FALSE)) {
      yearRas <-
      suppressWarnings(
        postProcess(stack[[currentRas]],
                    rasterToMatch = rtm,
                    studyArea = studyArea,
                    filename2 = NULL,
                    method = "bilinear",
                    useCache = cacheClimateRas)
      )
    } else {
      yearRas <- stack[[currentRas]]
    }

    #need to suppress warnings about resampling method - it SHOULD be bilinear

    if (all(is.na(getValues(yearRas)))){
      #this shouldn't occur unless due to bugs in ClimateNA
      message(crayon::yellow(paste0(names(yearRas),
                                    " for this specific study area is all NA. Using previous years' raster ("
                                    , names(stack[[currentRas - 1]]), ")")))
      currentRas <- currentRas - 1
      yearRas <- postProcess(stack[[currentRas]],
                             rasterToMatch = rtm,
                             studyArea = studyArea,
                             filename2 = NULL,
                             method = "bilinear",
                             useCache =  cacheClimateRas)
    }


  } else {
    if (time > 2100){
      message(crayon::yellow(paste0("The current time (", time,") is > 2100 and there are no predictions for this year.
                                    Using climate predictions for 2100")))
      currentRas <- raster::nlayers(stack)
      yearRas <- postProcess(stack[[currentRas]],
                             rasterToMatch = rtm,
                             studyArea = studyArea,
                             filename2 = NULL,
                             method = "bilinear",
                             useCache =  cacheClimateRas)
    } else {
      message(red(paste0("no climate effect for year ", time)))
      #assume it is not yet 2011, pass raster with all 0s
      yearRas <- rasterToMatch #Make a NULL raster for no climate effect
      yearRas[!is.na(rasterToMatch)] <- 0
    }
  }

  #this is a safety catch in case there are NAs due to the resampling ---
  #there may be due to the disparity in spatial resolution - 16/01/2020 Still haven't solved this from 4.5 km to 250 m
  medianVals <- median(getValues(yearRas), na.rm = TRUE)
  if (!is.null(yearRas[is.na(yearRas) & !is.na(rtm)])) {
    yearRas[is.na(yearRas) & !is.na(rtm)] <- medianVals
  }

  if (isATA == TRUE) {
    #ATA was stored as an integer AND as tenth of a degree. So divide by 10 to get actual degrees
    yearRas[] <- yearRas[]/10
    if (max(yearRas[], na.rm = TRUE) > 100) {
      stop("ATA values do not appear to have converted to degrees. Please read over expected inputs")
    }
  }


  return(yearRas)
}

#moved this function out of lapply so the 3.5 GB environment isnt cached everytime
pspIntervals <- function(i, M, P, Clim){

  #Calculate climate variables.
  #ACMI and ATA were added individually in separate model
  CMI <- mean(Clim$CMI[Clim$Year >= P$MeasureYear[i] &
                         Clim$Year <= P$MeasureYear[i+1]])
  ACMI <- mean(Clim$CMI[Clim$Year >= P$MeasureYear[i] &
                          Clim$Year <= P$MeasureYear[i+1]]) - P$CMI[1]
  ATA <- mean(Clim$MAT[Clim$Year >= P$MeasureYear[i] &
                         Clim$Year <= P$MeasureYear[i+1]]) - P$MAT[1]
  AT <- mean(Clim$MAT[Clim$Year >= P$MeasureYear[i] &
                        Clim$Year <= P$MeasureYear[i+1]])
  period <- paste0(P$MeasureYear[i], "-", P$MeasureYear[i+1])

  m1 <- M[MeasureYear == P$MeasureYear[i]]
  m2 <- M[MeasureYear == P$MeasureYear[i + 1]]
  censusLength <- P$MeasureYear[i + 1] - P$MeasureYear[i]
  year <- ceiling(sum(P$MeasureYear[i] + P$MeasureYear[i + 1])/2)
  living1 <- m1[m1$TreeNumber %in% m2$TreeNumber]
  living2 <- m2[m2$TreeNumber %in% m1$TreeNumber]
  dead <- m1[!m1$TreeNumber %in% m2$TreeNumber]
  newborn <- m2[!m2$TreeNumber %in% m1$TreeNumber]

  if (nrow(living1) != nrow(living2)) {
    stop('there is a problem with the PSP dataset. Contact ian.eddy@canada.ca')
  }
  #Find observed annual changes in mortality and growth
  living2$origBiomass <- living1$biomass
  living <- living2[, .(newGrowth =  sum(biomass - origBiomass)/censusLength),
                    c("Species", "newSpeciesName")] %>%
    setkey(., Species, newSpeciesName)
  #growth cannot be negative by definition. So if a reduction in DBH occured, this will count as 0
  living[newGrowth < 0, newGrowth := 0]

  newborn <- newborn[, .(newGrowth = sum(biomass)/(censusLength/2)), c("Species", "newSpeciesName")] %>%
    setkey(., Species, newSpeciesName)
  #measure from census midpoint for new seedlings
  dead <- dead[, .(mortality = sum(biomass)/censusLength), by = c("Species", "newSpeciesName")] %>%
    setkey(., Species, newSpeciesName)

  #Find unobserved growth and mortality.
  #Not necessary when summing by species, b/c we can't assign species for unobserved trees
  #Unobserved growth and mortality = ~1% of observed, so climate influences on this are trivial.
  #Leaving this in nonetheless, in case we change methods
  #Unobserved recruits U = N * R * M * L
  #N = # of trees with DBH between 10 and 15
  # N <- nrow(m2[DBH <= 15]) #TODO ask Yong if this is m2, or total
  # #R = number of recruits between two successive censuses (trees in t2 not in t1)/census length
  # R <- nrow(newborn)/censusLength/N #I am not 100% sure if we divide by N or total stems in plot
  # #M = Mortality rate, n-trees with DBH 10 -15 that died between two census/interval length
  # M <- nrow(dead[DBH <= 15,])/censusLength/N
  # #L = census interval length
  # #Next calculate the median growth of the 10-15 DBH class, assume they grew to midpoint.
  # UnobservedR <- N * R * M * censusLength
  # UnobservedM <- UnobservedR * median(m2$biomass[m2$DBH <= 15])/censusLength/2
  # #assume unobserved trees died at midpoint. I think this overestimates growth and mortality
  # totalM <- UnobservedM + observedMortality
  # totalG <- UnobservedM + observedGrowth

  changes <- bind(newborn, living)

  #to prevent error if any table is empty
  changes$mortality <- 0
  dead$newGrowth <- 0

  changes <- bind(changes, dead)
  changes[is.na(changes)] <- 0
  changes <- changes[, .("netGrowth" = sum(newGrowth), "mortality" = sum(mortality)),
                     by = c("Species", "newSpeciesName")]
  changes <- changes[, .("species" = Species,
                         "sppLong" = newSpeciesName,
                         "netBiomass" = (netGrowth - mortality),
                         "growth" = netGrowth,
                         mortality)]

  changes$period <- period
  changes$CMI <- CMI
  changes$CMIA <- ACMI
  changes$ATA <- ATA
  changes$OrigPlotID1 <- P$OrigPlotID1[1]
  changes$year <- year
  changes$standAge <- P$baseSA[1] + P$MeasureYear[i+1] - P$MeasureYear[1]
  changes$logAge <- log(changes$standAge)
  changes$plotSize <- P$PlotSize[1]
  changes$periodLength <- censusLength
  changes$AT <- AT

  setcolorder(changes, c("OrigPlotID1", "period", "species", "sppLong", "growth", "mortality", "netBiomass",
                         "CMI", "CMIA", "AT", "ATA", "standAge", "logAge", "plotSize", "periodLength"))
  return(changes)

}

sumPeriod <- function(x, rows, m, p, clim){
  x <- rows[x,]
  #Duplicate plots arise from variable 'stand' (OrigPlotID2) that varied within the same plot.
  #this has been corrected by treating these as new plot ids.
  #TODO: review this code and confirm if it is still necessary
  #Tree No. is not unique between stands, which means the same plot can have duplicate trees.
  #sort by year. Calculate the changes in biomass, inc. unobserved growth and mortality
  #must match MeasureID between plot and measure data; OrigPlotID2 not present in P
  m <- m[OrigPlotID1 == x$OrigPlotID1,] #subset data by plot
  p <- p[MeasureID %in% m$MeasureID]
  clim <- clim[OrigPlotID1 %in% x,]
  p <- setkey(p, MeasureYear)
  m <- setkey(m, TreeNumber)
  periods <- nrow(p) - 1

  #For each interval
  pSums <- lapply(1:periods, FUN = pspIntervals, M = m, P = p, Clim = clim)

  pSums <- rbindlist(pSums)
  return(pSums)
}

.inputObjects <- function(sim) {

  cacheTags <- c(currentModule(sim), "function:.inputObjects")

  dPath <- asPath(getOption("reproducible.destinationPath", dataPath(sim)), 1)
  message(currentModule(sim), ": using dataPath '", dPath, "'.")

  if (!suppliedElsewhere("PSPmeasure", sim) | !suppliedElsewhere("PSPplot", sim) | !suppliedElsewhere("PSPgis", sim) ) {
    stop("You have not supplied PSP data. Please run PSP_Clean or supply the objects to simInit")
  }

  if (!suppliedElsewhere("studyArea", sim)) {
    message("studyArea not supplied. Using a random area in Alberta")
    sim$studyArea <- randomStudyArea(size = 1e6*50)
  }

  if (!suppliedElsewhere("PSPclimData", sim)) {
    sim$PSPclimData <- prepInputs(url = extractURL("PSPclimData"),
                                  targetFile = "PSPforClimateNA_1901-2019Y.csv",
                                  destinationPath = dPath,
                                  fun = "data.table::fread")
    setnames(sim$PSPclimData, old = c("id1", "id2"), new = c("OrigPlotID1", "OrigPlotID2"))
  }

  if (!suppliedElsewhere("ATAstack", sim)) {
    #These should not be called using rasterToMatch (stack, memory)
    if (P(sim)$GCM == "CCSM4_RCP4.5") {
      ata.url <- 'https://drive.google.com/open?id=1sGRp0zNjlQUg6LXpEgG4anT2wx1jvuUQ'
      ata.tf <- "Can3ArcMinute_CCSM4_RCP45_ATA2011-2100.grd"
      ata.arc <- 'Canada3ArcMinute_CCSM4_45_ATA2011-2100.zip'
    } else if (P(sim)$GCM == "CanESM2_RCP4.5") {
      ata.url <- "https://drive.google.com/open?id=1d8wy70gxDcO2MKsQt7tYBpryKudE-99h"
      ata.tf <- "Can3ArcMinute_CanESM2_RCP45_ATA2011-2100.grd"
      ata.arc <- 'Canada3ArcMinute_ATA2011-2100.zip'
    } else if (P(sim)$GCM == "CCSM4_RCP8.5") {
      ata.url <- 'https://drive.google.com/open?id=1_LXyPRdWbUj_Kk3ab-bgjqDXcowg_lpM'
      ata.tf <- 'Can3ArcMinute_CCSM4_RCP85_ATA2011-2100.grd'
      ata.arc <- 'Canada3ArcMinute_CCSM4_85_ATA2011-2100.zip'
    } else {
      stop("unrecognized GCM in P(sim)$GCM")
    }

    sim$ATAstack <- prepInputs(targetFile = ata.tf,
                               archive = ata.arc,
                               alsoExtract = "similar",
                               url = ata.url,
                               destinationPath = dPath,
                               fun = "raster::stack",
                               useCache = TRUE,
                               userTags = c(currentModule(sim), "ATAstack")
    ) #if a pixel is 10 degrees above average, needs 4S
  }

  if (!suppliedElsewhere("CMIstack", sim)) {
    if (P(sim)$GCM == "CCSM4_RCP4.5") {
      cmi.url <- 'https://drive.google.com/open?id=1ERoQmCuQp3_iffQ0kXN7SCQr07M7dawv'
      cmi.tf <- "Canada3ArcMinute_CCSM4_45_CMI2011-2100.grd"
      cmi.arc <- 'Canada3ArcMinute_CCSM4_45_CMI2011-2100.zip'
    } else if (P(sim)$GCM == "CanESM2_RCP4.5") {
      cmi.url <- "https://drive.google.com/open?id=1MwhK3eD1W6u0AgFbRgVg7j-qqyk0-3yA"
      cmi.tf <- "Canada3ArcMinute_CMI2011-2100.grd"
      cmi.arc <- "Canada3ArcMinute_CMI2011-2100.zip"
    } else if (P(sim)$GCM == "CCSM4_RCP8.5") {
      cmi.url <- 'https://drive.google.com/open?id=1OcVsAQXKO4N4ZIESNmIZAI9IZcutctHX'
      cmi.tf <- 'Canada3ArcMinute_CCSM4_85_CMI2011-2100.grd'
      cmi.arc <- 'Canada3ArcMinute_CCSM4_85_CMI2011-2100.zip'
    } else {
      stop("unrecognized GCM in P(sim)$GCM")
    }
    #These should not be called with RasterToMatch
    sim$CMIstack <- prepInputs(targetFile = cmi.tf,
                               archive = cmi.arc,
                               alsoExtract = "similar",
                               url = cmi.url,
                               destinationPath = dPath,
                               fun = "raster::stack",
                               useCache = TRUE,
                               userTags = c(currentModule(sim), "CMIstack")
    )
  }

  if (!suppliedElsewhere("rasterToMatch", sim)) {
    message("rasterToMatch not supplied. Generating from LCC2005")
    sim$rasterToMatch <- prepInputsLCC(studyArea = sim$studyArea, filename2 = NULL, destinationPath = dPath)
  }

  if (!suppliedElsewhere("CMInormal", sim)) {

    sim$CMInormal <- prepInputs(targetFile = 'Canada3ArcMinute_normalCMI.grd',
                                archive = 'Canada3ArcMinute_normalCMI.zip',
                                url = 'https://drive.google.com/open?id=16YMgx9t2eW8-fT5YyW0xEbjKODYNCiys',
                                destinationPath = dPath,
                                fun = "raster::raster",
                                studyArea = sim$studyArea,
                                rasterToMatch = sim$rasterToMatch,
                                useCache = TRUE,
                                overwrite = TRUE,
                                userTags = c(currentModule(sim), "CMInormal"),
                                method = 'bilinear',
                                alsoExtract = "Canada3ArcMinute_normalCMI.gri")
  }
  return(invisible(sim))
}
### add additional events as needed by copy/pasting from above
