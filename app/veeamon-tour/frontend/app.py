import os
import time

import pymysql
from flask import Flask, redirect, render_template, request, url_for

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_USER = os.environ.get("DB_USER", "root")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "veeamon_tour")

# Placeholder demo data - not the real VeeamON Tour schedule. Replace with
# actual dates/venues if this is used for anything beyond a DR demo.
SEED_STOPS = [
    ("Sydney", "Australia", "2026-09-15", "ICC Sydney"),
    ("Singapore", "Singapore", "2026-09-22", "Marina Bay Sands Expo"),
    ("London", "United Kingdom", "2026-10-06", "ExCeL London"),
    ("New York", "United States", "2026-10-20", "Javits Center"),
    ("Sao Paulo", "Brazil", "2026-11-03", "Transamerica Expo Center"),
]


def get_connection(database=None):
    return pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=database,
        cursorclass=pymysql.cursors.DictCursor,
    )


def init_db():
    last_error = None
    for _ in range(30):
        try:
            conn = get_connection()
            with conn.cursor() as cur:
                cur.execute(f"CREATE DATABASE IF NOT EXISTS {DB_NAME}")
            conn.commit()
            conn.close()

            conn = get_connection(DB_NAME)
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS tour_stops (
                        id INT AUTO_INCREMENT PRIMARY KEY,
                        city VARCHAR(100) NOT NULL,
                        country VARCHAR(100) NOT NULL,
                        event_date DATE NOT NULL,
                        venue VARCHAR(200) NOT NULL
                    )
                    """
                )
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS checkins (
                        id INT AUTO_INCREMENT PRIMARY KEY,
                        name VARCHAR(100) NOT NULL,
                        city VARCHAR(100) NOT NULL,
                        message VARCHAR(280) NOT NULL,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    )
                    """
                )
                cur.execute("SELECT COUNT(*) AS c FROM tour_stops")
                if cur.fetchone()["c"] == 0:
                    cur.executemany(
                        "INSERT INTO tour_stops (city, country, event_date, venue) VALUES (%s, %s, %s, %s)",
                        SEED_STOPS,
                    )
            conn.commit()
            conn.close()
            return
        except pymysql.err.OperationalError as exc:
            last_error = exc
            time.sleep(2)
    raise RuntimeError(f"Could not reach database after retries: {last_error}")


@app.route("/")
def index():
    conn = get_connection(DB_NAME)
    with conn.cursor() as cur:
        cur.execute("SELECT city, country, event_date, venue FROM tour_stops ORDER BY event_date")
        stops = cur.fetchall()
        cur.execute("SELECT COUNT(*) AS c FROM checkins")
        count = cur.fetchone()["c"]
        cur.execute("SELECT name, city, message, created_at FROM checkins ORDER BY id DESC LIMIT 20")
        checkins = cur.fetchall()
    conn.close()
    return render_template("index.html", stops=stops, count=count, checkins=checkins)


@app.route("/checkin", methods=["POST"])
def checkin():
    name = request.form.get("name", "").strip()[:100]
    city = request.form.get("city", "").strip()[:100]
    message = request.form.get("message", "").strip()[:280]
    if name and city and message:
        conn = get_connection(DB_NAME)
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO checkins (name, city, message) VALUES (%s, %s, %s)",
                (name, city, message),
            )
        conn.commit()
        conn.close()
    return redirect(url_for("index"))


@app.route("/healthz")
def healthz():
    return "ok", 200


@app.route("/api/count")
def api_count():
    conn = get_connection(DB_NAME)
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS c FROM checkins")
        count = cur.fetchone()["c"]
    conn.close()
    return {"count": count}


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
