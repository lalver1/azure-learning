import os

from flask import (Flask, redirect, render_template, request,
                   send_from_directory, url_for)
from azure.monitor.opentelemetry import configure_azure_monitor

configure_azure_monitor()

app = Flask(__name__)


@app.route('/')
def index():
   print('Request for index page received')
   return render_template('index.html')

@app.route('/favicon.ico')
def favicon():
    return send_from_directory(os.path.join(app.root_path, 'static'),
                               'favicon.ico', mimetype='image/vnd.microsoft.icon')

@app.route('/hello', methods=['POST'])
def hello():
   name = request.form.get('name')

   if name.lower() == "exception":
       raise Exception("Generic test exception")
   elif name.lower() == "valueerror":
       raise ValueError("This is a ValueError for testing")
   elif name.lower() == "keyerror":
       raise KeyError("This is a KeyError for testing")
   elif name.lower() == "zerodivision":
       return str(1 / 0)  # Triggers ZeroDivisionError
   elif name.lower() == "typeerror":
       return "Length is: " + len(5)  # TypeError: object of type 'int' has no len()
   elif name.lower() == "customerror":
    class CustomError(Exception):
        pass
    raise CustomError("This is a custom-defined exception")
   elif name:
    print('Request for hello page received with name=%s' % name)
    return render_template('hello.html', name = name)
   else:
    print('Request for hello page received with no name or blank name -- redirecting')
    return redirect(url_for('index'))


if __name__ == '__main__':
   app.run()
