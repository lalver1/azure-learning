import logging
import os
import requests

import azure.functions as func

app = func.FunctionApp()

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL")


@app.route(route="alert_to_slack", auth_level=func.AuthLevel.FUNCTION, methods=["POST"])
def alert_to_slack(req: func.HttpRequest) -> func.HttpResponse:
    """
    Receives an alert from Azure Monitor, formats it, and sends it to Slack via webhook.
    """
    logging.info("alert_to_slack processed a request.")

    try:
        alert_data = req.get_json()
    except ValueError:
        return func.HttpResponse("Request body is not valid JSON.", status_code=400)

    data = alert_data.get("data", {})
    essentials = data.get("essentials", {})
    alert_id = essentials.get("alertId", "N/A")
    alert_rule = essentials.get("alertRule", "N/A")
    severity = essentials.get("severity", "N/A")
    fired_date_time = essentials.get("firedDateTime", "N/A")
    investigation_link = essentials.get("investigationLink", "#")

    message = (
        f"*Azure Alert ID: {alert_id}*\n"
        f"*Azure Alert Fired: {alert_rule}*\n\n"
        f"*Severity*: {severity}\n"
        f"*Date*: {fired_date_time}\n\n"
        f"<{investigation_link}|Click here to view the alert in Azure Portal>"
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