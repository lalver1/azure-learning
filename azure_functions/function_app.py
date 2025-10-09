# changedd
import logging
import os
import requests
import json

import azure.functions as func

app = func.FunctionApp()

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL")
FUNCTION_KEY = os.environ.get("AZURE_FUNCTION_KEY")


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

    additional_details = ""
    alert_context = data.get("alertContext", {})
    search_results = alert_context.get("SearchResults") if alert_context else None

    # Check if this is a log-based alert with search results
    if search_results and search_results.get("tables"):
        tables = search_results["tables"]
        if tables and tables[0].get("rows"):
            main_table = tables[0]
            # Create a map of column names to their index
            column_map = {col['name']: i for i, col in enumerate(main_table.get("columns", []))}
            first_row = main_table["rows"][0]  # Process the first result row

            # Helper function to safely get data from the row using the column map
            def get_field(field_name, default="N/A"):
                index = column_map.get(field_name)
                if index is not None and index < len(first_row):
                    value = first_row[index]
                    return value if value else default # Return default if value is empty
                return default

            # Helper function to format JSON strings for readability
            def format_json_field(raw_json_string):
                if not raw_json_string or raw_json_string == "N/A":
                    return "N/A"
                try:
                    parsed_json = json.loads(raw_json_string)
                    return f"```\n{json.dumps(parsed_json, indent=2)}\n```"
                except (json.JSONDecodeError, TypeError):
                    return raw_json_string # Return as-is if not valid JSON

            # Extract all required fields
            problem_id = get_field("problemId")
            outer_message = get_field("outerMessage")
            innermost_message = get_field("innermostMessage")
            client_os = get_field("client_OS")
            client_city = get_field("client_City")
            client_browser = get_field("client_Browser")
           
            # Format potentially complex fields
            details = format_json_field(get_field("details"))
            custom_dimensions = format_json_field(get_field("customDimensions"))

            # Build the additional details string
            additional_details = (
                f"*Problem ID*: {problem_id}\n"
                f"*Client OS*: {client_os}\n"
                f"*Client Browser*: {client_browser}\n"
                f"*Client City*: {client_city}\n\n"
                f"*Outer Message*: \n>{outer_message}\n\n"
                f"*Innermost Message*: \n>{innermost_message}\n\n"
                f"*Custom Dimensions*: \n{custom_dimensions}\n\n"
                f"*Details*: \n{details}\n"
            )

    message = (
        f"🚨 *Azure Alert Fired: {alert_rule}*\n\n"
        f"*Severity*: {severity}\n"
        f"*Date*: {fired_date_time}\n"
        f"*Alert ID*: {alert_id}\n\n"
        f"---------------------------------------------------\n"
        f"{additional_details}"
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