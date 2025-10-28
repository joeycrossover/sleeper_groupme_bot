library(shiny)
library(shinydashboard)
library(dplyr)
library(tidyverse)
library(openxlsx)
library(DT)
library(data.table)
library(ggplot2)
library(ggforce)
library(bslib)
library(countdown)

league_history <- readxl::read_xlsx("champs.xlsx")

# set current week
current_week <- 9
previous_week <- current_week - 1

# league users ----
league_users <- jsonlite::fromJSON(httr::content(httr::GET(paste0("https://api.sleeper.app/v1/league/", 
                                                                  "1256817986006683648", 
                                                                  "/users")), as = "text"))
league_users <- league_users %>% 
  select(-avatar) %>% 
  unnest(metadata) %>% 
  select(-starts_with("mascot_item")) %>% 
  select(user_id, avatar, display_name, team_name)

league_users$avatar_img <- ifelse(
  is.na(league_users$avatar) | league_users$avatar == "NA",
  "",
  paste0('<img src="', league_users$avatar,
         '" style="width:20px;height:20px;border-radius:50%;">')
)

league_users <- league_users %>%
  mutate(team_name = paste(avatar_img, team_name)) %>%
  select(user_id, display_name, team_name)

# matchups ----
get_matchups <- function(week) {
  tryCatch({
    x <- jsonlite::fromJSON(
      httr::content(
        httr::GET(
          paste0(
            "https://api.sleeper.app/v1/league/",
            "1256817986006683648",
            "/matchups/",
            week
          )
        ),
        as = "text"
      )
    )
    
    if (is.null(x) || length(x) == 0) {
      return(NULL)  # API returned empty
    }
    
    x <- x %>%
      unnest(starters_points) %>%
      unnest(starters) %>% 
      select(-starts_with("players")) %>%
      select(points, roster_id, matchup_id) %>%
      distinct()
    
    x
  },
  error = function(e) {
    message("No matchups found for week ", week, ". Returning NULL.")
    NULL
  })
}

all_matchups <- NULL

for (i in 1:14) {
  week_matchups <- get_matchups(i)
  if (!is.null(week_matchups)) {
    week_matchups$week <- i
    all_matchups <- rbind(all_matchups, week_matchups)
  }
}

# team rosters ----
rosters <- jsonlite::fromJSON(httr::content(httr::GET(paste0("https://api.sleeper.app/v1/league/", 
                                                             "1256817986006683648", 
                                                             "/rosters")), as = "text"))
rosters <- rosters %>% 
  unnest(settings) %>% 
  unnest(metadata) %>%
  select(-contains("p_nick")) %>% 
  select(-contains("pn_")) %>%
  mutate(fpts = fpts + (fpts_decimal / 100),
         fpts_against = fpts_against + (fpts_against_decimal / 100),
         ppts = ppts + (ppts_decimal / 100)) %>%
  select(owner_id, roster_id, players, reserve, waiver_position, fpts, fpts_against, 
         ppts, wins, losses, ties, streak)

# standings ----
standings <- merge(league_users, rosters, by.x = "user_id", by.y = "owner_id") %>%
  select(team_name, display_name, wins, losses, streak, 
         fpts, fpts_against, ppts, waiver_position) %>%
  arrange(desc(wins), desc(fpts))

# incentives ----
pf_lead <- standings %>%
  filter(fpts == max(fpts))
weekly_high <- merge(all_matchups, rosters, by = "roster_id") %>%
  merge(., league_users, by.x = "owner_id", by.y = "user_id") %>%
  arrange(desc(points)) %>% head(1)

# power rankings ----
power_rankings <- readRDS("power_rankings.rds") # the code below can be run once per week, or at all times
# completed_weeks <- merge(all_matchups, rosters, by = "roster_id") %>%
#   merge(., league_users, by.x = "owner_id", by.y = "user_id") %>%
#   filter(week <= previous_week) %>%
#   select(display_name, team_name, matchup_id, week, points, fpts, ppts, wins, losses, ties, streak) %>%
#   rename("wk_pf" = points,
#          "total_pf" = fpts)
# cumulative_standings <- NULL
# for (i in unique(completed_weeks$week)) {
#   week_standings <- completed_weeks %>%
#     filter(week %in% i)
#   for (i in unique(week_standings$matchup_id)) {
#     matchup <- week_standings %>%
#       filter(matchup_id %in% i)
#     matchup$wins <- ifelse(matchup$wk_pf == max(matchup$wk_pf), 1, 0)
#     matchup$losses <- ifelse(matchup$wk_pf == min(matchup$wk_pf), 1, 0)
#     matchup$wk_win <- ifelse(matchup$wk_pf == max(matchup$wk_pf), 1, 0)
#     matchup$wk_loss <- ifelse(matchup$wk_pf == min(matchup$wk_pf), 1, 0)
#     cumulative_standings <- rbind(cumulative_standings, matchup)
#   }
# }
# cumulative_standings <- cumulative_standings %>%
#   group_by(team_name) %>%
#   arrange(week) %>%
#   mutate(total_pf = cumsum(wk_pf),
#          wins = cumsum(wins),
#          losses = cumsum(losses)) %>%
#   mutate(pfp = round(total_pf / ppts, 3)) %>%
#   ungroup()
# cumulative_standings <- cumulative_standings %>%
#   group_by(team_name) %>%
#   arrange(week) %>%
#   mutate(
#     streak = {
#       streak_count <- 0
#       streak_vector <- character(n())
#       for (i in seq_len(n())) {
#         if (wk_win[i] == 1) {
#           streak_count <- if (i == 1 || wk_win[i - 1] == 0) 1 else streak_count + 1
#           streak_vector[i] <- paste0(streak_count, "W")
#         } else {
#           streak_count <- if (i == 1 || wk_loss[i - 1] == 0) 1 else streak_count + 1
#           streak_vector[i] <- paste0(streak_count, "L")
#         }
#       }
#       streak_vector
#     }
#   ) %>%
#   ungroup()
# cumulative_standings <- cumulative_standings %>%
#   group_by(week) %>%
#   arrange(desc(wins), desc(total_pf)) %>%
#   mutate(standings = row_number()) %>%
#   ungroup()
# cumulative_standings$streak_num <- as.numeric(sub("[WL]", "", cumulative_standings$streak))
# cumulative_standings$streak_num <- case_when(
#   grepl("W$", cumulative_standings$streak) ~ cumulative_standings$streak_num,
#   grepl("L$", cumulative_standings$streak) ~ -cumulative_standings$streak_num
# )
# cumulative_standings <- cumulative_standings %>%
#   group_by(week) %>%
#   mutate(wk_win_rank = rank(-wk_win),
#          wins_rank = rank(-wins),
#          loss_rank = rank(losses),
#          wk_pf_rank = rank(-wk_pf),
#          total_pf_rank = rank(-total_pf),
#          pfp_rank = rank(-pfp),
#          streak_rank = rank(-streak_num)) %>%
#   ungroup()
# # keep_obj <- c("all_matchups", "cumulative_standings", "league_users", "pf_lead", "power_rankings", "league_history",
# #                 "rosters", "standings", "weekly_high", "current_week", "previous_week", "get_matchups")
# # all_obj <- ls()
# # remove_obj <- setdiff(all_obj, keep_obj)
# # rm(list = remove_obj)
# # remove(all_obj, remove_obj)
# completed_week_standings <- cumulative_standings %>%
#   filter(week %in% previous_week)
# previous_week_rankings <- power_rankings %>%
#   filter(week %in% (previous_week - 1))
# completed_week_standings$Prev <- previous_week_rankings$Rk[match(completed_week_standings$display_name, previous_week_rankings$display_name)]
# completed_week_standings <- completed_week_standings %>%
#   rowwise() %>%
#   mutate(
#     Rk = weighted.mean(
#       c(Prev, standings, wk_win_rank, wins_rank, loss_rank, wk_pf_rank, total_pf_rank, pfp_rank, streak_rank),
#       c(1,     1,          1,        3,         1,         2,          5,            2,        1)  # weights
#     )
#   ) %>%
#   ungroup()
# completed_week_standings$Rk <- rank(completed_week_standings$Rk)
# completed_week_standings <- completed_week_standings %>%
#   mutate(`Chg` = Prev - Rk)
# power_rankings <- rbind(power_rankings, completed_week_standings)
# saveRDS(power_rankings, "power_rankings.rds")

# playoffs ----
# playoffs <- jsonlite::fromJSON(httr::content(httr::GET(paste0("https://api.sleeper.app/v1/league/",
#                                                               "1256817986006683648",
#                                                               "/winners_bracket")), as = "text")) %>%
#   rename("winner" = w,
#          "loser" = l) %>%
#   unnest(t1_from) %>%
#   rename("winner_from_1" = w,
#          "loser_from_1" = l) %>%
#   unnest(t2_from) %>%
#   rename("winner_from_2" = w,
#          "loser_from_2" = l) %>%
#   filter(!is.na(winner_from_1) |
#            !is.na(winner_from_2) |
#            r == 1) %>%
#   select(m, r, t1, t2, winner_from_1, winner_from_2)
# playoffs <- playoffs %>%
#   pivot_longer(., cols = -c(m, r, winner_from_1, winner_from_2),
#                names_to = "team",
#                values_to = "roster_id")
# playoffs <- merge(playoffs, rosters, by = "roster_id", all = TRUE)
# playoffs <- playoffs %>%
#   filter(!is.na(r))
# playoffs <- merge(playoffs, league_users, by.x = "owner_id", by.y = "user_id", all = TRUE)
# playoffs <- playoffs %>%
#   filter(!is.na(r))
# playoffs <- playoffs %>%
#   select(m, r, display_name, team_name, wins, losses, winner_from_1, winner_from_2)
# colnames(playoffs) <- c("match_id", "round", "manager", "team", "wins", "losses", "winner_from_1", "winner_from_2")
# 
# nodes <- playoffs %>%
#   arrange(match_id) %>%
#   mutate(node_id = paste0("M", match_id, "_", row_number() %% 2 + 1),
#          label = ifelse(!is.na(team),
#                         paste0(team, " (", wins, "-", losses, ")"),
#                         "")) %>%
#   select(node_id, label) %>%
#   distinct() %>%
#   mutate(id = node_id)

# players list ----
players <- jsonlite::fromJSON(httr::content(httr::GET(paste0("https://api.sleeper.app/v1/players/nfl")), as = "text"))

extract_player_info <- function(player) {
  data.frame(
    player_id = ifelse(!is.null(player$player_id), player$player_id, NA),
    fantasy_positions = ifelse(!is.null(player$fantasy_positions), player$fantasy_positions, NA),
    team = ifelse(!is.null(player$team), player$team, NA),
    first_name = ifelse(!is.null(player$first_name), player$first_name, NA),
    last_name = ifelse(!is.null(player$last_name), player$last_name, NA),
    stringsAsFactors = FALSE
  )
}

players <- do.call(rbind, lapply(players, extract_player_info)) %>%
  filter(!is.na(team)) %>%
  filter(fantasy_positions %in% c("QB", "RB", "WR", "TE", "K", "DEF")) %>%
  mutate(name = paste(first_name, last_name, sep = " ")) %>%
  select(player_id, name, fantasy_positions, team) %>%
  rename("position" = fantasy_positions)

# saveRDS(player_data, "all_players.rds")
# players <- readRDS("all_players.rds")

# user interface ----
ui <- dashboardPage(
  dashboardHeader(title = tags$a(
    href = 'https://sleeper.com/leagues/1256817986006683648/league',
    tags$img(src = "https://sleepercdn.com/avatars/thumbs/4f108f189297f058c0d12350f82f8571", 
             height = '40', width = '40', style = "margin-right: 10px;"),
    tags$span("GBURG FFL", style = "font-weight: bold; color: white;"))),
  dashboardSidebar(
    sidebarMenu(
      menuItem("Home", tabName = "home", icon = icon("home")),
      menuItem("Matchups", tabName = "matchups", icon = icon("gamepad")),
      menuItem("Rosters", tabName = "rosters", icon = icon("list")),
      menuItem("Power Rankings", tabName = "rankings", icon = icon("chart-line")),
      menuItem("Podcast EPs", tabName = "podcasts", icon = icon("headphones")))),
  dashboardBody(
    tabItems(
      tabItem(tabName = "home",
              h1("Welcome to the G-Burg All Grown Up Fantasy Football League Shiny App. 
                 Please use the sidebar to navigate the app, or click the logo in the top left to visit the league in Sleeper."),
              br(),
              # h2("",
              #    style = "color: red; font-weight: bold;"),
              # br(),
              # tags$h3("2025 Playoff Bracket"),
              # h4(tags$img(src = "bracket3.png",
              #             style = "max-width: 100%; height: auto; background: transparent;")),
              br(),
              h4(tags$span("League Incentive Watch 💰", 
                           style = "font-family: 'Arial Black', sans-serif; font-weight: bold;")),
              br(),
              fluidRow(
                tags$style(HTML(".info-box {border: 2px solid black;}")),
                infoBoxOutput("pf_leader", width = 4),
                infoBoxOutput("weekly_pf_leader", width = 4),
                infoBoxOutput("rs_champ", width = 4)),
              br(),
              h4(tags$span("League Standings 📊", 
                           style = "font-family: 'Arial Black', sans-serif; font-weight: bold;")),
              br(),
              tags$style(HTML("
              .standings-table .dataTable {
              border: 2px solid black;  /* Adds a black border around the entire table */
              }
              .standings-table thead th {
              background-color: yellow !important;  /* Highlights header row in yellow */
              color: black;  /* Change the header text color to black (optional) */
              font-weight: bold;  /* Makes header text bold */
              }
              .standings-table tbody td {
              background-color: white !important;  /* Ensures table body has a white background */
              color: black;  /* Text color in table body */
              }
              .standings-table table.dataTable.stripe tbody tr:nth-child(odd) {
              background-color: white !important;  /* Removes default stripe styling */
              }
              .standings-table table.dataTable.stripe tbody tr:nth-child(even) {
              background-color: white !important;  /* Removes default stripe styling */
              }")),
              tags$div(class = "standings-table",
                       dataTableOutput("standings")),
              br(),
              h4(tags$span("League Champions 🏆", 
                           style = "font-family: 'Arial Black', sans-serif; font-weight: bold;")),
              br(),
              tags$div(class = "standings-table",
                       dataTableOutput("history"))),
      tabItem(tabName = "matchups",
              h2(tags$span("Weekly Matchups 📅", 
                           style = "font-family: 'Arial Black', sans-serif; font-weight: bold;")),
              br(),
              selectInput("select_week_matchup", "Select Week",
                          choices = 1:14,
                          selected = previous_week),
              uiOutput("scoreboard")),
      tabItem(tabName = "rosters",
              h2(tags$span("League Rosters 📋", 
                           style = "font-family: 'Arial Black', sans-serif; font-weight: bold;")),
              br(),
              selectInput("select_team", "Select Team",
                          choices = c("All", league_users$team_name)),
              tags$div(class = "standings-table",
                       dataTableOutput("rosters"))),
      tabItem(tabName = "rankings",
              h2(tags$span("Real MF Power Rankings 💪🔥", 
                           style = "font-family: 'Arial Black', sans-serif; font-weight: bold;")),
              br(),
              selectInput("select_week_pr", "Select Week",
                          choices = 1:previous_week,
                          selected = previous_week),
              tags$div(class = "standings-table",
                       dataTableOutput("pr"))),
      tabItem(tabName = "podcasts",
              h2(tags$span("Podcast EPs 🎙",
                           style = "font-family: 'Arial Black', sans-serif; font-weight: bold;")),
              br(),
              fluidRow(
                box(
                  title = "Episode 1 (2025): ft Mike the Commish and Cole World's Joe Coleman",
                  width = 6,
                  tags$iframe(
                    src = "https://www.youtube.com/embed/GJHwQ3AOPAE?si=PVdiXq8HBlchrUGE",
                    width = "560",
                    height = "315",
                    frameborder = "0",
                    allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen = TRUE)),
                box(
                  title = "Episode 6: Playoff Preview",
                  width = 6,
                  tags$iframe(
                    src = "https://www.youtube.com/embed/GJHwQ3AOPAE?si=PVdiXq8HBlchrUGE",
                    width = "560",
                    height = "315",
                    frameborder = "0",
                    allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen = TRUE)),
                box(
                  title = "Episode 5: ft Billy Cullen, owner/GM of Bill's Mafia",
                  width = 6,
                  tags$iframe(
                    src = "https://www.youtube.com/embed/IOPq50lu2q8?si=AzcHTp3cKrZqKzIn",
                    width = "560",
                    height = "315",
                    frameborder = "0",
                    allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen = TRUE)),
                box(
                  title = "Episode 4: ft Post-Game Interview with Joe Coleman (Cole World)",
                  width = 6,
                  tags$iframe(
                    src = "https://www.youtube.com/embed/bU3NpKoMBpM?si=C3RMXlHVqh7GhCS9",
                    width = "560",
                    height = "315",
                    frameborder = "0",
                    allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen = TRUE)),
                box(
                  title = "Episode 3: ft Kyle Dillon and Ben Sandberg",
                  width = 6,
                  tags$iframe(
                    src = "https://www.youtube.com/embed/Ss0b_grqaII?si=Bi6lbkuqVVBxxbyq",
                    width = "560",
                    height = "315",
                    frameborder = "0",
                    allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen = TRUE)),
                box(
                  title = "Episode 2: ft League Commissioner, Michael Toomer Jr.",
                  width = 6,
                  tags$iframe(
                    src = "https://www.youtube.com/embed/xDV5XcbbqiU?si=PJILz0SmeVkHTZ0P",
                    width = "560",
                    height = "315",
                    frameborder = "0",
                    allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen = TRUE)),
                box(
                  title = "Episode 1: Barry Hackey introduces the new GBurg All Grown Up FFL Podcast",
                  width = 6,
                  tags$iframe(
                    src = "https://www.youtube.com/embed/TOkhSIWqp8Y?si=TsHyhr69ln0FxI9t",
                    width = "560",
                    height = "315",
                    frameborder = "0",
                    allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",
                    allowfullscreen = TRUE)))
              )
    )
  )
)

# server ----
server <- function(input, output, session) {
  
  output$standings <- renderDataTable({
    DT::datatable(standings  %>%
                    rename("Manager" = "display_name",
                           "Team" = "team_name",
                           "W" = "wins",
                           "L" = "losses",
                           "Streak" = "streak",
                           "PF" = "fpts",
                           "PA" = "fpts_against",
                           "PPTS" = "ppts",
                           "Waiver Order" = "waiver_position"),
                  escape = FALSE,
                  options = list(pageLength = -1,
                                        dom = 't'))
  })
  
  output$pf_leader <- renderInfoBox({
    infoBox(
      "PF Leader, $50", 
      HTML(paste0(pf_lead$team_name, " (", pf_lead$fpts, ")")),
      icon = icon("usd", lib = "glyphicon"),
      color = "green"
    )
  })

  output$weekly_pf_leader <- renderInfoBox({
    infoBox(
      "Weekly PF Leader, $50", 
      HTML(paste0(weekly_high$team_name, 
                  " (", weekly_high$points, ", Wk ", weekly_high$week, ")")),
      icon = icon("usd", lib = "glyphicon"),
      color = "green"
    )
  })

  output$rs_champ <- renderInfoBox({
    infoBox(
      "Regular Season Champion, $100", 
      HTML(standings$team_name[1]),
      icon = icon("usd", lib = "glyphicon"),
      color = "green"
    )
  })
  
  # output$bracket <- renderPlot({
  #   create_bracket(playoffs)
  # })
  
  output$history <- renderDataTable({
    DT::datatable(league_history, rownames = FALSE, options = list(pageLength = -1, dom = 't'))
  })
  
  observe({
    input$select_team
    input$select_week_matchup
    input$select_week_pr
  })
  
  filtered_matchups <- reactive({
    weekly_matchups <- get_matchups(input$select_week_matchup) %>%
      arrange(matchup_id)
    roster_ids <- rosters %>%
      select(owner_id, roster_id, wins, losses)
    weekly_matchups <- merge(weekly_matchups, roster_ids, by = "roster_id")
    weekly_matchups <- merge(weekly_matchups, league_users, by.x = "owner_id", by.y = "user_id") %>%
      select(display_name, team_name, matchup_id, points, wins, losses) %>%
      arrange(matchup_id)
    weekly_matchups
  })
  
  output$scoreboard <- renderUI({
    score_table <- filtered_matchups()
    matchups <- lapply(1:6, function(id) {
      matchup_data <- score_table %>%
        filter(matchup_id == id)
      table_id <- paste0("matchup_table_", id)
      box(
        title = paste("Game", id),
        width = 6,
        status = "primary",
        solidHeader = TRUE,
        collapsible = TRUE,
        div(style = "width: 100%;",
            DTOutput(table_id))
      )
    })
    fluidRow(
      do.call(tagList, matchups)
    )
  })
  
  lapply(1:6, function(id) {
    table_id <- paste0("matchup_table_", id)
    output[[table_id]] <- renderDT({
      matchup <- filtered_matchups() %>% 
        filter(matchup_id == id) %>%
        select(team_name, points, wins, losses) %>%
        mutate(is_winner = ifelse(points == max(points), "yes", "no"),
               team_name = paste(team_name, "    (", wins, "-", losses, ")", sep = "")) %>%
        select(team_name, points, is_winner) %>%
        rename("Team" = team_name,
               "Score" = points)
      # print(input$select_week_matchup)
      # print(current_week)
      # print(input$select_week_matchup >= current_week)
      if (input$select_week_matchup >= current_week) {
        datatable(matchup, 
                  escape = FALSE,
                  options = list(dom = 't', 
                                 paging = FALSE,
                                 columnDefs = list(list(visible = FALSE, targets = 2))), 
                  rownames = FALSE)
      } else {
        datatable(matchup, 
                  escape = FALSE,
                  options = list(dom = 't', 
                                 paging = FALSE, 
                                 columnDefs = list(list(visible = FALSE, targets = 2))), 
                  rownames = FALSE) %>%
          formatStyle(
            'is_winner',
            target = 'row',
            backgroundColor = styleEqual("yes", "yellow"),
            fontWeight = styleEqual("yes", "bold")
          )
        }
    })
  })
  
  output$rosters <- renderDataTable({
    selected_team <- input$select_team
    all_rosters <- rosters %>%
      select(owner_id, players) %>%
      unnest(players)
    all_rosters <- merge(all_rosters, league_users, by.x = "owner_id", by.y = "user_id")
    all_rosters <- merge(all_rosters, players, by.x = "players", by.y = "player_id", all.x = TRUE) %>%
      filter(!is.na(name))
    if (selected_team %in% "All") {
      all_rosters <- all_rosters %>%
        select(display_name, team_name, name, position, team) %>%
        rename("Manager" = display_name,
               "Team" = team_name,
               "Player" = name,
               "Position" = position,
               "Player Team" = team)
    } else {
      all_rosters <- all_rosters %>%
        filter(team_name %in% selected_team) %>%
        select(team_name, display_name, name, position, team) %>%
        rename("Manager" = display_name,
                 "Team" = team_name,
                 "Player" = name,
                 "Position" = position,
               "Player Team" = team)
    }
    table_options <- if (selected_team == "All") {
      list()
    } else {
      list(pageLength = -1, dom = 't')
    }
    DT::datatable(all_rosters, escape = FALSE, options = table_options)
  })
  
  output$pr <- renderDataTable({
    power_rankings <- power_rankings %>%
      filter(week %in% input$select_week_pr) %>%
      arrange(Rk, standings) %>%
      mutate(Trend = case_when(
        as.numeric(Prev) > Rk ~ "<span style='color:green; font-size:1.5em;'>&uarr;</span>",
        as.numeric(Prev) < Rk ~ "<span style='color:red; font-size:1.5em;'>&darr;</span>",
        TRUE ~ "-")) %>%
      mutate(total_pf = round(total_pf, 2)) %>%
      select(Rk, Prev, Trend, team_name, display_name, wins, losses, wk_pf, total_pf, pfp, streak) %>%
      rename("Manager" = "display_name",
               "Team" = "team_name",
               "W" = "wins",
               "L" = "losses",
               "Streak" = "streak",
               "PF" = total_pf,
               "Week PF" = wk_pf,
             "PFP" = pfp,
             " " = Trend)
      DT::datatable(power_rankings, escape = FALSE, rownames = FALSE, options = list(pageLength = -1,
                                            dom = 't'))
  })
  
}

# app ----
shinyApp(ui = ui, server = server)
