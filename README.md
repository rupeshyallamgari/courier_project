# Courier Parcel Booking and Tracking Management System

Database: MySQL 8.0.16+ | Backend: Python Flask | Frontend: HTML + JavaScript

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/rupeshyallamgari/courier_project)

## Folder structure
- database/setup.sql            tables, constraints, indexes, triggers, sample data, report views
- database/practice_queries.sql full script with extra queries and constraint tests (paste step by step)
- backend/app.py                Flask REST API connected to MySQL
- frontend/index.html           web interface (served by Flask)

## How to run (Windows Command Prompt)
1. Install Python 3.9+ and MySQL 8, then in this folder:  pip install -r requirements.txt
2. Create the database:  mysql -u root -p < database\setup.sql
3. Set your MySQL password:  set DB_PASSWORD=your_password
4. Start the server:  python backend\app.py
5. Open http://localhost:5000 in your browser.

## Features
Parcel booking with automatic charge calculation, tracking scans and route movement, agent assignment,
delivery update, failed-attempt handling, payments, customer CRUD, search, and 6 reports.
Business rules (unique tracking number, positive weight and charge, scan sequence, no scan after delivery,
payment limit) are enforced by the database itself; errors appear as red messages in the page.
