# changedd
import logging
import os
import requests
import json

import azure.functions as func

app = func.FunctionApp()

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL")
FUNCTION_KEY = os.environ.get("AZURE_FUNCTION_KEY")
APPINSIGHTS_API_KEY = os.environ.get("APPINSIGHTS_API_KEY")

def fetch_log_details(api_link):
    headers = {"x-api-key": APPINSIGHTS_API_KEY}
    response = requests.get(api_link, headers=headers)
    response.raise_for_status()
    data = response.json()
    data_str = json.dumps(data, indent=2) # pretty print 2 spaces indent
    if len(data_str) > 10000:  # 1 byte per char, roughly 10KB, Azure limits to 64KB
        data_str = data_str[:10000] + "... [truncated]"
    logging.info(f"Fetched log details: {data_str}")
    return data["tables"][0]["rows"][0] if data["tables"] else {}

@app.route(route="alert_to_slack", auth_level=func.AuthLevel.ANONYMOUS, methods=["POST"])
def alert_to_slack(req: func.HttpRequest) -> func.HttpResponse:
    """
    Receives an alert from Azure Monitor, formats it, and sends it to Slack via webhook.
    """
    logging.info("alert_to_slack processed a request.")

    provided_code = req.params.get("CODE")
    if not provided_code:
        return func.HttpResponse("Missing CODE authentication.", status_code=401)
    if provided_code != FUNCTION_KEY:
        logging.warning("Invalid CODE provided.")
        return func.HttpResponse("Unauthorized: invalid CODE.", status_code=403)
    
    try:
        alert_data = req.get_json()
    except ValueError:
        return func.HttpResponse("Request body is not valid JSON.", status_code=400)

    data = alert_data.get("data", {})
    
    try:
        data_str = json.dumps(data, indent=2) # pretty print 2 spaces indent
        if len(data_str) > 10000:  # 1 byte per char, roughly 10KB, Azure limits to 64KB
            data_str = data_str[:10000] + "... [truncated]"
        logging.info(f"Received Azure alert data:\n{data_str}")
    except Exception as e:
        logging.warning(f"Failed to serialize alert data for logging: {e}")
    
    essentials = data.get("essentials", {})
    alert_id = essentials.get("alertId", "N/A")
    alert_rule = essentials.get("alertRule", "N/A")
    severity = essentials.get("severity", "N/A")
    fired_date_time = essentials.get("firedDateTime", "N/A")
    investigation_link = essentials.get("investigationLink", "#")
    
    alert_context = data.get("alertContext", {})
    condition = alert_context.get("condition", {})
    api_link = condition.get("allOf", {[]})[0].get("linkToSearchResultsAPI", "#")
    latest_alert_details = fetch_log_details(api_link)

    message = (
        f"🚨 *Azure Alert Fired: {alert_rule}*\n\n"
        f"*Severity*: {severity}\n"
        f"*Date*: {fired_date_time}\n"
        f"*Alert ID*: {alert_id}\n\n"
        f"---------------------------------------------------\n"
        f"{latest_alert_details}"
        f"<{investigation_link}|Click here to investigate in Azure Portal>"
    )

    slack_payload = {"text": message}

    try:
        response = requests.post(SLACK_WEBHOOK_URL, json=slack_payload)
        response.raise_for_status()  # Raise an exception for bad status codes
        logging.info(f"Successfully sent message to Slack. Status: {response.status_code}")
        return func.HttpResponse("Alert successfully forwarded to Slack.", status_code=200)

    except requests.exceptions.RequestException as e:
        logging.error(f"Error sending message to Slack: {e}")
        return func.HttpResponse(f"Error sending to Slack: {e}", status_code=500)

@app.route(route="health", auth_level=func.AuthLevel.ANONYMOUS, methods=["GET"])
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """
    A simple health check endpoint
    """
    logging.info("Health check endpoint was triggered.")
    return func.HttpResponse("Healthy.", status_code=200)