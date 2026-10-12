"""Dev entrypoint:  flask --app run run --debug   (or)   python run.py"""
from app import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=9999, debug=True)
