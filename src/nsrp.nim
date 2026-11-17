const
  pkgTitle*       = "nsrp: Nim Steam Review Parser"
  pkgVersion*     = "2026.09.07.1"
  pkgAuthor*      = "Michael Adams, unquietwiki@gmail.com"
  pkgDescription* = "Download Steam(TM) game reviews into three different formats"
  # A real browser User-Agent. Steam's anti-bot layer flags the default
  # "Nim HttpClient" UA, so present as a normal desktop browser.
  steamUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

# Libraries
import std/[httpclient, json, net, os, parseopt, re, streams, strscans, strutils, times, uri]
import markdown

# Global variables
var
  reviewLimit: int = 0
  dataDirectory: string = "."
  steamid: int = 0
  # Optional Steam session cookie (e.g. "sessionid=...") supplied via -c.
  # A logged-in session is what usually gets the appreviews endpoint to
  # return JSON instead of a bot-block page.
  sessionCookie: string = ""
let
  timeIsNow = now().utc

# Claude-generated function to isolate a substring
proc nchars(input: string; strVal: var string; start: int; n: int): int =
  ## Matches exactly `n` characters.
  if start + n <= input.len:
    strVal = input[start ..< start + n]
    result = n
  # else result stays 0 -> match fails (also validates the length is exactly n)

# Make sure data directory exists
proc prepareDataDir(dirData: string) =
  if(dirData != "."):
    if(not dirExists(dirData)):
      createDir(dirData)

# Build an HTTP client that looks like a normal browser and, when a Steam
# session cookie was supplied (see -c), sends it on every request.
proc newSteamClient(): HttpClient =
  result = newHttpClient(steamUserAgent)
  if sessionCookie.len > 0:
    result.headers.add("Cookie", sessionCookie)

# Grab the name of the game/application from API
proc grabTitleAndReleaseDate(): (string, string) =
  var
    client = newSteamClient()
    title = "COULD NOT RETREIVE TITLE"
    releaseDate = "UNRELEASED"
  try:
    let
      url: string = "https://store.steampowered.com/api/appdetails" & "?appids=" & $steamid
      response = client.get(url)
      pageJSON = parseJson(response.body)
    title = pageJSON{$steamid}{"data"}{"name"}.getStr()
    releaseDate = pageJSON{$steamid}{"data"}{"release_date"}{"date"}.getStr()
  except:
    echo "Could not retrieve JSON appdetails data from Steam"
  finally:
    client.close()
    return (title, releaseDate)

# Grab JSON fragment from API
proc grabAPIData(cursor: string, numPerPage: int = 100): string =  
  var
    client = newSteamClient()
    rawData: string = ""
  try:
    echo "Using cursor: " & cursor
    let
      requestValues: string = "json=1&filter=updated&purchase_type=all&language=all&filter_offtopic_activity=1&num_per_page=" & $numPerPage & "&cursor=" & encodeUrl(cursor)
      url: string = "https://store.steampowered.com/appreviews/" & $steamid & "?" & requestValues
      response = client.get(url)
    rawData = response.body
  except:
    echo "Could not retrieve JSON appreviews data from Steam"
  finally:
    client.close()
    return rawData

# Grab initial data and return as a JSON Object
proc grabData(): (JsonNode) =
  var
    newData: string = ""
    rawData: string = ""
    cursor: string = "*"
    skip: string = ""
    oldcursor: string = ""
    arrayOfJSON = newJArray()
    newJSON = newJObject()
    totalFetched: int = 0
  try:
    # Okay... so, we're gonna grab the data, shrinking each request to only ask
    # for as many records as we still need (capped at 100 per page), and chain
    # the cursor until we hit the limit or run out of new pages.
    echo "Retrieving data ..."
    while (true):
      var numPerPage = 100
      if reviewLimit > 0:
        let remaining = reviewLimit - totalFetched
        if remaining <= 0:
          break
        numPerPage = min(100, remaining)
      newData = grabAPIData(cursor, numPerPage)
      let pageJSON = parseJson(newData)
      arrayOfJSON.add(pageJSON)
      var pageCount = 0
      if pageJSON.contains("reviews"):
        pageCount = pageJSON["reviews"].len
        totalFetched += pageCount
      echo "Page returned " & $pageCount & " reviews (requested " & $numPerPage & ")"
      if (reviewLimit > 0 and totalFetched >= reviewLimit):
        break
      if pageCount < numPerPage:
        break # Steam gave back fewer than we asked for; no more data to page through
      if scanf(newData, "$*\"cursor\":$s\"${nchars(20)}\"", skip, cursor):
        if (cursor == oldcursor):
          break
        echo "More records found: " & cursor
        rawData &= newData
        oldcursor = cursor
      else:
        break # no cursor in the response; stop instead of re-requesting forever
    echo "Data pages loaded: " & $arrayOfJSON.len

    # Verify data is valid before proceeding to build out new, cleaner JSON to use
    if(arrayOfJSON[0].contains("query_summary") and arrayOfJSON[0].contains("reviews")):
      newJSON.add("query_summary", arrayOfJSON[0]["query_summary"])
      newJSON.add("reviews", newJArray())
      var added = 0
      for i in 0 ..< arrayOfJSON.len:
        for j in 0 ..< arrayOfJSON[i]["reviews"].len:
          if (reviewLimit > 0 and added >= reviewLimit):
            break
          newJSON["reviews"].add(arrayOfJSON[i]["reviews"][j])
          inc added
    
  except:
    echo "Could not process JSON data"
  finally:
    return (newJSON)

# Build one row of a Markdown table from a list of cell contents
proc mdTableRow(cells: seq[string]): string =
  "| " & cells.join(" | ") & " |"

# Generate Markdown format of JSON data
proc makeMarkdown(jsonData: JsonNode, filename: string): (bool) =
  # Steam's anti-bot layer answers blocked/anonymous requests with a
  # "Welcome to Steam" HTML page instead of JSON. That surfaces here as an
  # empty/invalid JSON tree; detect it and fail with a clear message rather
  # than crashing on a missing node further down.
  if not (jsonData.contains("query_summary") and jsonData.contains("reviews") and jsonData["reviews"].len > 0):
    echo "Steam did not return any review data for this app."
    echo "This is usually Steam's bot protection: the appreviews endpoint"
    echo "answered with a 'Welcome to Steam' page instead of JSON."
    echo "Try again later, from a different network, or with a logged-in"
    echo "Steam session. See https://store.steampowered.com/appreviews/"
    return false
  var
    titleAndRelease = grabTitleAndReleaseDate()
    streamMD = newFileStream(filename, fmWrite)
  if not isNil(streamMD):
    # Header & summary
    streamMD.writeLine("# Steam Reviews of " & titleAndRelease[0])
    streamMD.writeLine("## Summary")
    streamMD.writeLine("- **DateTime of Report (UTC):** " & $timeIsNow.format("MMM dd, yyyy, HH:mm"))
    streamMD.writeLine("- **Release Date:** " & titleAndRelease[1])
    streamMD.writeLine("- **Total Reviews:** " & $jsonData["query_summary"]["total_reviews"].getInt())
    streamMD.writeLine("- **Positive Reviews:** " & $jsonData["query_summary"]["total_positive"].getInt())
    streamMD.writeLine("- **Negative Reviews:** " & $jsonData["query_summary"]["total_negative"].getInt())
    streamMD.writeLine("- **Overall Sentiment:** " & jsonData["query_summary"]["review_score_desc"].getStr())
    streamMD.writeLine("## Latest " & $jsonData["reviews"].len & " Reviews")
    streamMD.flush()
    # Cycle through reviews
    for i in 0 ..< jsonData["reviews"].len:
      let
        activeRow = jsonData["reviews"][i]
        playtimeHrs = activeRow["author"]["playtime_forever"].getInt() / 60
      streamMD.writeLine("### Review by: [" & activeRow["author"]["personaname"].getStr() &
        "](" & activeRow["author"]["profile_url"].getStr() & ")")
      streamMD.writeLine()
      # Stats
      if(activeRow["timestamp_updated"].getInt() != activeRow["timestamp_created"].getInt()):
        streamMD.writeLine("**Updated review (UTC):** _" & $fromUnix(activeRow["timestamp_updated"].getInt()).utc.format("yyyy-MM-dd HH:mm") & "_")
      else:
        streamMD.writeLine("**Reviewed (UTC):** _" & $fromUnix(activeRow["timestamp_created"].getInt()).utc.format("yyyy-MM-dd HH:mm") & "_")
      # Reviewer stats as a table with a blank header row: GFM tables require
      # a header, but leaving the cells empty skips the bold title bar you'd
      # get from a "real" header, while still lining the columns up cleanly.
      var statCells: seq[string] = @[
        "**Total user reviews made:** _" & $activeRow["author"]["num_reviews"].getInt() & "_",
        "**Playtime:** _" & playtimeHrs.formatFloat(ffDecimal, 2) & " hours_"
      ]
      if activeRow["refunded"].getBool():
        statCells.add("**REFUNDED**")
      if activeRow["received_for_free"].getBool():
        statCells.add("**RECEIVED FOR FREE**")
      var sepCells = newSeq[string](statCells.len)
      for idx in 0 ..< sepCells.len:
        sepCells[idx] = "---"
      streamMD.writeLine(mdTableRow(newSeq[string](statCells.len)))
      streamMD.writeLine(mdTableRow(sepCells))
      streamMD.writeLine(mdTableRow(statCells))
      streamMD.writeLine()
      # System specs: note that VRAM is an Int, but others are strings, and CPU string has to be "stripped".
      try:
        if(activeRow.contains("hardware")):
          streamMD.writeLine("**CPU:** _" & activeRow["hardware"]["cpu_name"].getStr().strip() & "_" &
            "; **Video Card:** _" & activeRow["hardware"]["adapter_description"].getStr() & "_" &
            "; **VRAM (MB):** _" & $activeRow["hardware"]["vram_size"].getInt() & "_" &
            "; **System RAM (MB):** _" & activeRow["hardware"]["system_ram"].getStr() & "_" &
            "; **OS:** _" & activeRow["hardware"]["os"].getStr() & "_")
        else:
          streamMD.writeLine("_No system specs provided_")
      except:
        streamMD.writeLine("_No system specs provided_")
      # Write out actual review
      if activeRow["voted_up"].getBool():
        streamMD.writeLine("#### Positive Review ")
      else:
        streamMD.writeLine("#### Negative Review ")
      let reviewText = activeRow["review"].getStr()
      streamMD.writeLine("```")
      streamMD.writeLine(reviewText)
      streamMD.writeLine("```")
      streamMD.writeLine()
      streamMD.writeLine()
      streamMD.flush()
    # Close file
    streamMD.close()
  echo "Parsing JSON into usable Markdown"  
  return true

let
  # The "markdown" library doesn't render GFM pipe-tables, so the blank
  # header/separator rows built by mdTableRow() survive as literal text.
  # Strip that leftover syntax and replace it with a line break instead.
  brokenTableHeaderPattern = re(r"\|(?:\s+\|)+\s*\n\|(?:\s*-{3,}\s*\|)+\s*\n")
  # The remaining data row (e.g. "| **Total...** | **Playtime:**... |")
  # still carries its pipe delimiters; this matches that row so its cells
  # can be rejoined without them.
  statRowPattern = re(r"<br>\n\|(.*?)\|(?=</p>|\n)")

# Rejoins the cells of a leftover stats data row (see statRowPattern above)
# with "; " instead of the unrendered Markdown pipe delimiters.
proc cleanStatRowPipes(html: string): string =
  result = html
  var pos = 0
  while true:
    var caps = newSeq[string](1)
    let bounds = findBounds(result, statRowPattern, caps, pos)
    if bounds.first < 0:
      break
    var cleaned = "<br>\n"
    let cells: seq[string] = caps[0].split(" | ")
    for i, cell in cells:
      if i > 0: cleaned.add("; ")
      cleaned.add(cell.strip())
    result = result[0 ..< bounds.first] & cleaned & result[bounds.last + 1 .. ^1]
    pos = bounds.first + cleaned.len

# Generate HTML file from converted Markdown
proc makeHTML(filenameMD: string, filenameHTML: string): (bool) =
  try:
    let textMD = readFile(filenameMD)
    let bodyHTML = markdown(textMD).replace(brokenTableHeaderPattern, "<br>\n").cleanStatRowPipes()
    let textHTML = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n" &
      "<meta charset=\"UTF-8\">\n" &
      "<title>" & pkgTitle & "</title>\n" &
      "<style>\n" &
      "body {\n" &
      "  font-family: Consolas, Monaco, 'Courier New', monospace;\n" &
      "}\n" &
      "pre {\n" &
      "  white-space: pre-wrap;\n" &
      "  background: #f4f4f4;\n" &
      "  border-left: 4px solid #888;\n" &
      "  border-radius: 4px;\n" &
      "  padding: 0.75em 1em;\n" &
      "  margin: 0.5em 0 1.5em;\n" &
      "}\n" &
      "pre code {\n" &
      "  background: none;\n" &
      "}\n" &
      "@media (prefers-color-scheme: dark) {\n" &
      "  pre { background: #2a2a2a; border-left-color: #666; color: #ddd; }\n" &
      "}\n" &
      "</style>\n" &
      "</head>\n<body>\n" & bodyHTML & "\n</body>\n</html>\n"
    writeFile(filenameHTML, textHTML)
    return true
  except:
    echo "Could not render Markdown into HTML: " & getCurrentExceptionMsg()
    return false

# Write out help if no valid input is given
proc writeHelp() =
  echo "=============================================================="
  echo pkgTitle, "; ", pkgVersion
  echo pkgAuthor
  echo pkgDescription
  echo ""
  echo "Add a review limit: nsrp -n:REVEWLIMIT (subsequent command)"
  echo "Specify output dir: nsrp -d:DIRECTORY  (subsequent command)"
  echo "Steam session cookie: nsrp -c:COOKIE   (subsequent command, e.g. 'sessionid=...')"
  echo "JSON:               nsrp -j:STEAMID"
  echo "Markdown:           nsrp -m:STEAMID"
  echo "HTML:               nsrp -h:STEAMID"
  echo "=============================================================="

# === Parse command line ===
for kind, key, val in getopt():
  case kind
  of cmdLongOption, cmdShortOption:
    case key
    of "d":
      try:
        echo "Setting data output directory to " & val
        dataDirectory = val
      except ValueError:
        echo "Incorrect directory specified"
        quit(1)
    of "n":
      try:
        reviewLimit = parseInt(val)
        echo "Limiting to the latest ", reviewLimit, " reviews ..."
      except ValueError:
        echo "Must enter a valid integer for review limit"
        quit(1)
    of "c":
      sessionCookie = val
      echo "Using supplied Steam session cookie."
    of "m":
      try:
        steamid = parseInt(val)
        echo "Outputting Markdown for SteamID ", $steamid
        var data = grabData()
        prepareDataDir(dataDirectory)
        let filenameMD = os.joinPath(dataDirectory, $steamid & "_review.md")
        if(makeMarkdown(data, filenameMD)):
          echo "Markdown generated: please review " & filenameMD
        else:
          echo "Failed to produce Markdown"
          quit(1)
        quit(0)
      except ValueError:
        echo "Must enter a valid integer for SteamID"
        quit(1)
    of "h":
      try:
        steamid = parseInt(val)
        echo "Outputting HTML for SteamID ", $steamid
        var data = grabData()
        prepareDataDir(dataDirectory)
        let filenameMD = os.joinPath(dataDirectory, $steamid & "_review.md")
        let filenameHTML = os.joinPath(dataDirectory, $steamid & "_review.html")
        if(makeMarkdown(data, filenameMD)):
          echo "Markdown generated: please review " & filenameMD
          if(makeHTML(filenameMD, filenameHTML)):
            echo "Rendered to HTML: " & filenameHTML
        else:
          echo "Failed to produce Markdown"
          quit(1)
        quit(0)
      except ValueError:
        echo "Must enter a valid integer for SteamID"
        quit(1)
    of "j":
      try:
        steamid = parseInt(val)
        echo "Outputting JSON for SteamID ", $steamid
        var data = grabData()
        if not (data.contains("query_summary") and data.contains("reviews") and data["reviews"].len > 0):
          echo "Steam did not return any review data for this app (likely blocked by bot protection)."
          quit(1)
        prepareDataDir(dataDirectory)
        writeFile(joinPath(dataDirectory, $steamid & "_review.json"),pretty(data))
        quit(0)
      except ValueError:
        echo "Must enter a valid integer for SteamID"
        quit(1)
    else:
      writeHelp()
      quit(0)
  of cmdArgument:
    writeHelp()
    quit(0)
  of cmdEnd:
    break
