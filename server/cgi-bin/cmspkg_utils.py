import os
import sys

blocked_user_agents = [
  "gptbot",
  "semrushbot",
  "claudebot",
  "googlebot",
  "dataforseobot",
  "uptimerobot",
  "applebot",
  "dotbot",
  "yandexbot",
  "backlinksextendedbot",
  "bingbot",
  "aliyunsecbot",
]

def invalid_user_agent(msg, code):
  print ("Status: %s Not Found" % code)
  print ("Content-type: text/html\n")
  print (msg)
  sys.exit(0)

def check_user_agent():
  if not blocked_user_agents:
    return
  user_agent = os.environ.get("HTTP_USER_AGENT", "").lower()
  if not user_agent:
    invalid_user_agent("ERROR USER_AGENT", 404)
  for agent in blocked_user_agents:
    if agent in user_agent:
      invalid_user_agent("ERROR", 403)
  return
