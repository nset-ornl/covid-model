###############################################################
# FUNCTIONS

# Function to take a state and root directory, and return a data_frame
#  with one column containing all sample csv paths
get_sample_paths <- function(STATE, ROOT){
  SAMP_DIR <- file.path(ROOT, STATE)
  csv.files <- list.files(SAMP_DIR,
                          pattern='samples.*[0-9]\\.csv$',
                          full.names=TRUE)
  return(csv.files)
  # return(tibble(chain_csv = csv.files))
}

# Function to create tidy object from list of files:

read_stan_draws <- function(files, par_select, warmup=500) {
  #Input: files: a dataframe
  #csv_files_col_name: character: names of column with paths to csvs
  # Output: a long dataframe with samples
  par_enquo <- rlang::enquo(par_select)
  samples <- tibble(files=files) %>%
    mutate(.chain=1:n()) %>%
    #mutate(samples = map(.x=!!sym(csv_files_col_name),
    #                     ~read_csv(.x, comment='#'))) %>%
    mutate(samples = map(.x=files,
                         ~vroom_stan(.x, col_select=!!par_enquo))) %>%
    mutate(samples = map(.x=samples, ~mutate(.x,.iteration=1:n() ))) %>%
    unnest(cols=samples) %>%
    mutate(.draw = 1:n()) %>%
    filter(.iteration > warmup) %>%
    select(.draw, .chain, .iteration, !!par_enquo) %>%
    ungroup() %>%
    pivot_longer(cols=!!par_enquo,names_to='.variable', values_to='.value')
  return(samples)
}

# Function to take a dataframe of samples, and a paramater string and 
#  calculate rhat for all matching pars (start_with(par))
calculate_rhat <- function(samples, warmup=0,par){
  temp <- samples %>%
    filter(.iteration > warmup) %>%
    select(.chain, .iteration, starts_with(par)) %>%
    pivot_longer(cols=starts_with(par),names_to='.variable', values_to='.value')
  NCHAINS = max(temp$.chain)
  NITER = max(temp$.iteration)
  grand_mean <- temp %>% group_by(.variable) %>% summarize(gmean=mean(.value))
  chain_summary <- temp %>% 
    group_by(.chain, .variable) %>% 
    summarize(wmean = mean(.value), wvar = var(.value)) %>%
    ungroup() %>%
    left_join(grand_mean, by='.variable') %>%
    group_by(.variable)   %>%
    summarize(W=mean(wvar), B = NITER /(NCHAINS-1) * sum((wmean-gmean)^2)) %>%
    mutate(V = (1-1/NITER) * W + 1/NITER * B,
           rhat = sqrt(V/W)) %>%
    summarize(max_rhat = max(rhat),
              which_max = .variable[which.max(rhat)],
              q99_rhat = quantile(rhat, .99),
              frac_gt_101 = mean(rhat>1.01))
  return(chain_summary)
}

# Function to take file names and read csv and calculate rhat summary
# INPUTS:
#  files: a character vector of stan sample files to process
#  warmup: # number of warmup samples
#  par_select: a tidy select of parameters to select (e.g. c(starts_with('b0_raw')))
#  k: will drop chain k from calculation r-hat (default NULL)
read_and_summarize <- function(files, par_select, warmup=0,  k=NULL){
  par_expr <- rlang::expr(par_select)
  par_enquo <- rlang::enquo(par_select)
  if(length(files)<3) {
    return(tibble(max_rhat = NA*0,
                  which_max = as(NA,'character'),
                  q99_rhat = NA*0,
                  frac_gt_101 = NA*0))
  }
  samples <- tibble(files=files) %>%
    mutate(.chain=1:n()) %>%
    #mutate(samples = map(.x=!!sym(csv_files_col_name),
    #                     ~read_csv(.x, comment='#'))) %>%
    mutate(samples = map(.x=files,
                         ~vroom_stan(.x, col_select=!!par_enquo))) %>%
    mutate(samples = map(.x=samples, ~mutate(.x,.iteration=1:n() ))) %>%
    unnest(cols=samples) %>%
    mutate(.draw = 1:n()) %>%
    select(.draw, .chain, .iteration, everything()) %>%
    ungroup()
  temp <- samples %>%
    filter(.iteration > warmup) %>%
    select(.chain, .iteration, par_select) %>%
    pivot_longer(cols=!!par_enquo,names_to='.variable', values_to='.value')
  NCHAINS = max(temp$.chain)
  NITER = max(temp$.iteration)
  if(!is.null(k)){
    # Delete a chain
    temp <- temp %>% filter(.chain != k)
    NCHAINS=NCHAINS-1
  }
  grand_mean <- temp %>% group_by(.variable) %>% summarize(gmean=mean(.value))
  chain_summary <- temp %>% 
    group_by(.chain, .variable) %>% 
    summarize(wmean = mean(.value), wvar = var(.value)) %>%
    ungroup() %>%
    left_join(grand_mean, by='.variable') %>%
    group_by(.variable)   %>%
    summarize(W=mean(wvar), B = NITER /(NCHAINS-1) * sum((wmean-gmean)^2)) %>%
    mutate(V = (1-1/NITER) * W + 1/NITER * B,
           rhat = sqrt(V/W)) %>%
    summarize(max_rhat = max(rhat),
              which_max = .variable[which.max(rhat)],
              q99_rhat = quantile(rhat, .99),
              frac_gt_101 = mean(rhat>1.01))
  return(chain_summary)
}

vroom_stan <- function(file, ...){
  # Stan sample files have commented out lines in the start, middle and end of the file
  # vroom can figure out the start, but not the middle and end
  # Use grep to delete those
  tfile <- paste0(file, '.tmp')
  grepcmd <- paste0("grep -vh '^#' ", file, " > ", tfile)
  system(grepcmd)
  out <- vroom::vroom(tfile, delim=',', num_threads=1, col_types=cols(.default=col_double()), ...)
  unlink(tfile)
  return(out)
}
