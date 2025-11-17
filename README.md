# Expense Tracker Application

A full-stack web application designed to help users manage shared expenses collaboratively in groups. Built with Python Flask backend and MySQL database, with a clean HTML/CSS/JavaScript frontend.

## Features

- User registration and login with session management
- Create and manage expense groups
- Add expenses with equal or custom splits among group members
- Track outstanding balances and settlements
- Automated settlement calculations and transaction minimization
- Secure, responsive, and user-friendly interface

## Getting Started

### Prerequisites

- Python 3.x
- MySQL Server
- pip (Python package manager)

### Installation

1. Clone this repository:
   
   git clone https://github.com/yourusername/expense-tracker.git
   cd expense-tracker
  

2. Install required Python packages:
  
   pip install -r requirements.txt
  

3. Setup the MySQL database:
   - Import the `database_setup.sql` file into your MySQL server to create the database and tables with sample data.

4. Configure database connection in `app.py` (update host, user, password as needed).

### Running the Application
``python app.py``
- The app runs locally on `http://127.0.0.1:5000/`
- Open the URL in your browser to use the application
