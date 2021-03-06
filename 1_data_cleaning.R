# Clean the data by removing merge conflicts, making nicer column names,
#   and counting up subjects who were excluded for one reason or another

library(readxl)
library(rms)
library(ordinal)
library(tidyverse)
library(lubridate)
library(MBESS)
library(censReg)
library(BayesFactor)
library(psych)
# install.packages('devtools'); library(devtools); install_github("Joe-Hilgard/hilgard")
library(hilgard)
library(lsmeans)


dat <- read.delim("full_data.txt", stringsAsFactors = F) %>% 
  slice(1:446) # discard the blank rows at the bottom
stash.names <- names(dat)

# remove debug rows
dat <- filter(dat, !(Subject %in% c(666, 900)))

# TODO: make session identifier (subjects within sessions)
# how do i do this?
# make date-time column
dat <- mutate(dat, 
              datetime = as_datetime(paste(dat$Date, substring(dat$Time, 12))),
              # ps within minutes of each other are same session
             datetime = floor_date(datetime, "10 mins"))

sessionInfo <- select(dat, datetime) %>% 
  filter(!is.na(datetime)) %>% 
  # group by datetime and count up n per session, then label sessions
  group_by(datetime) %>% 
  summarize(n = n()) %>% 
  mutate(session = 1:nrow(.))

# make a code if the previous session was in the same day and involved > 1 subject
sessionInfo <- mutate(sessionInfo, 
       prev_sesh_time = lag(datetime),
       prev_sesh_n = lag(n),
       cooldown = datetime - prev_sesh_time,
       warm_pitcher = case_when(prev_sesh_n > 1 & cooldown <= 60 ~ 1,
                                TRUE ~ 0))

# append sessionInfo data to full dataset
dat <- left_join(dat, sessionInfo, by = "datetime")

# look for missingness
sapply(dat, function(x) sum(is.na(x)))
# look for merge conflicts
select_if(dat, negate(is.POSIXt)) %>% 
  sapply(., function(x) sum(x == -999 | x == "CONFLICT!", na.rm = T))

# Create and rename columns ----

# rename Assignment to DV
dat = dat %>% 
  mutate(DV = Assignment)
# Add factor columns for violence & difficulty
dat$Violence = ifelse(dat$Condition == 1 | dat$Condition == 2, "Violent", "Less Violent")
dat$Difficulty = ifelse(dat$Condition == 2 | dat$Condition == 4, "Hard", "Easy")

# Add 2d4d ratios
dat$L2d4d = dat$L_index_length/dat$L_ring_length
dat$R2d4d = dat$R_index_length/dat$R_ring_length

# Count bad subjects ----
dir.create("debug")
fail.nodata <- dat %>% 
  filter(is.na(DV) | is.na(Violence) | is.na(Difficulty) | is.na(Condition))
write.csv(fail.nodata, file = "debug/missing_cond_DV.csv", row.names = F)
# conflicting DV or condition data
fail.conflict <- dat %>% 
  filter(DV == -999 | Condition == -999) 
write.csv(fail.conflict, file = "debug/conflicting_cond_DV.csv", row.names = F)

# died in easy-game condition
fail.easydie <- dat %>% 
  filter(Difficulty == "Easy", Game.1 > 0) %>% 
  select(Subject)

# took damage in easy-game condition
fail.easyharm <- dat %>% 
  filter(Difficulty == "Easy", Game.6 > 0) %>% 
  select(Subject)

# didn't take damage in hard-game condition???
fail.hard <- dat %>% 
  filter(Difficulty == "Hard", Game.6 == 0) %>% 
  select(Subject)
# 430 kills and no damage is deeply implausible, must be something wrong

# called hypothesis w/o wrong guesses
fail.savvy <- dat %>% 
  filter(Q1.a == 1 & (Q1.b == 0 & Q1.c == 0 & Q1.d == 0 & Q1.e == 0))  %>% 
  select(Subject)
dat %>% 
  mutate(savvy = ifelse(Q1.a == 1 & (Q1.b == 0 & Q1.c == 0 & Q1.d == 0 & Q1.e == 0), 0, 1))  %>% 
  with(table(Violence, savvy))
# are people more likely to be savvy under one condition?
dat %>% 
  mutate(savvy = ifelse(Q1.a == 1 & (Q1.b == 0 & Q1.c == 0 & Q1.d == 0 & Q1.e == 0), 0, 1))  %>%
  with(., chisq.test(Violence, savvy))

# RAs didn't think session went well
fail.badsesh <- dat %>% 
  filter(goodSession == "No") %>% 
  select(Subject)

# RA cited exp failure, 41
length(fail.badsesh$Subject)
#   plus took damage / died in easy game / took no damage in hard game, 3
length(setdiff(c(fail.easydie$Subject, fail.easyharm$Subject, fail.hard),
               fail.badsesh$Subject))
#   plus savvy to hypothesis, 114
length(setdiff(fail.savvy$Subject, 
               c(fail.easydie$Subject, fail.easyharm$Subject, fail.hard, 
                 fail.badsesh$Subject)))
#   plus no or conflicting data, 13
length(setdiff(c(fail.nodata$Subject, fail.conflict$Subject),
               c(fail.savvy$Subject, fail.easydie$Subject, fail.easyharm$Subject, fail.hard, 
                 fail.badsesh$Subject)))
# TODO: What if they say they knew their partner?
# Then the results are even more null re: game violence. hm

# geez, even after exclusions people say they aren't surprised they didn't trade essays
table(dat$Surprise)
# did i ever code up that 1-5 likert measure of suspicion? yes, Suspected
barplot(table(dat$Suspected))
# what are these conflicts now?

# Find and correct merge errors ----
# Here I gather all columns into one, 
# filter for merge errors, 
# then spread into subjects again
debug.dat <- dat %>% 
  gather(key, value, Q1.a:R2d4d) %>% 
  filter(value %in% c(-999, "CONFLICT!")) %>% 
  filter(!is.na(Subject)) %>% 
  spread(key = key, value = value)
# Add back in the column names with no conflicts for safety's sake
temp <- matrix(nrow = 1, ncol = length(stash.names))
temp <- as.data.frame(temp)
names(temp) <- stash.names
temp <- bind_rows(temp, debug.dat) %>% 
  filter(!is.na(Subject))

# sort into nice column order and export for RAs
write.csv(temp, "debug/master_baddata.csv", row.names = F, na = "")

# hyunji labeled irreconcilably bad or missing data as "BAD"
# I don't want to screw up my classes with character data so I'll treat that as NA
hyunji <- read_excel("debug/master_baddata.xlsx", na = c("", "BAD"))

# Function for overwriting merge conflicts with real values
force.numeric = function(x) {
  x <- x[x != -999] # discard conflicts
  # If all values are NA, return NA
  output <- ifelse(length(na.omit(x)) == 0, as.numeric(NA),
                   # otherwise, if all values are equal, merge them
                   ifelse(length(unique(na.omit(x))) == 1, unique(x),
                          # otherwise, return class-appropriate conflict code
                          -999))
  return(output)
}

# function for merging strings and flagging failures to match
force.character = function(x) {
  x <- x[x != "CONFLICT!"] # discard conflicts
  # If all values are NA, return NA
  output <- ifelse(length(na.omit(x)) == 0, as.character(NA),
                   # otherwise, if all values are equal, merge them
                   ifelse(length(unique(na.omit(x))) == 1, unique(x),
                          # otherwise, return class-appropriate conflict code
                          "CONFLICT!"))
  return(output)
}

# force dat$Subject to numeric
dat$Subject <- as.numeric(as.character(dat$Subject))
# separate by class and flatten
flatdat.num <- dat %>% 
  group_by(Subject) %>%
  select_if(is.numeric) %>% 
  gather(key, value, -Subject)
flatdat.chr <- dat %>% 
  group_by(Subject) %>% 
  select_if(is.character) %>% 
  gather(key, value, -Subject)
hyunji.num <- hyunji %>% 
  group_by(Subject) %>%
  select_if(is.numeric) %>% 
  gather(key, value, -Subject)
hyunji.chr <- hyunji %>% 
  group_by(Subject) %>% 
  select_if(is.character) %>% 
  gather(key, value, -Subject)

# Bind dataframes & use summarize() to force overwrite bad flatdat w/ hyunji's data
fused.num <- bind_rows(flatdat.num, hyunji.num) %>% 
  group_by(Subject, key) %>% 
  summarize(value = force.numeric(value))
fused.chr <- bind_rows(flatdat.chr, hyunji.chr) %>% 
  group_by(Subject, key) %>% 
  summarize(value = force.character(value))

# turn back into wide data
wide.num <- spread(fused.num, key, value)
wide.chr <- spread(fused.chr, key, value)
fixed.dat <- full_join(wide.num, wide.chr, by = "Subject")

# recover the date-time info
dat.datetime <- select(dat, Subject, datetime, prev_sesh_time, cooldown) 
fixed.dat <- left_join(fixed.dat, dat.datetime, by = "Subject")

# rearrange as the order it once was
fixed.dat <- fixed.dat %>% 
  select(names(dat))
dat <- fixed.dat

# Discard bad subjects ----
grep("fail*", ls(), value = T) # list all "fail" objects
# Filter out subjects who appear in any of the fail objects
dat.pure = dat %>% 
    filter(!(Subject %in% c(fail.badsesh$Subject, fail.conflict$Subject, fail.easydie$Subject, 
                          fail.easyharm$Subject, fail.hard$Subject, fail.nodata$Subject, 
                          fail.savvy$Subject)))



# TODO: Notes from old cleaning code ----
# may wish to use debriefing questionnaire columns:
#   Suspected_Debrief Game.play.affect.distraction.time_Debrief or Surprise_Debrief
# I probably ruined these questionnaires by having the RA attempt funneled debriefing and 
# then give the questionnaire... But if the funneled debriefing didn't turn up anything,
# the paper questionnaire should be legit!

# It looks like RA's decision of whether it was a good session or not
# had nothing to do with whether subject listed vg & aggression or suspicion of DV

# finally we can check whether warmer pitchers predict variance
lm(DV ~ warm_pitcher, data = dat) %>% summary()
lm(DV ~ cooldown, data = dat) %>% summary()

filter(dat, cooldown > 10, cooldown < 300) %>% 
  ggplot(aes(x = cooldown, y = DV, col = warm_pitcher)) +
  geom_smooth() +
  geom_jitter(width = 5, height = .1, alpha = .5)

# Export ----
write.table(dat.pure, "clean_data.txt", sep = "\t", row.names = F)
