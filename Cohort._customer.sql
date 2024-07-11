WITH filtered_users AS
(SELECT user_id
FROM sessions
WHERE session_start >= '2023-01-04'
GROUP BY user_id
HAVING COUNT(session_id) > 7),

 Cohort AS
(SELECT
    s.session_id, s.user_id, s.trip_id, s.session_start, s.session_end, s.page_clicks,
    s.flight_discount, s.flight_discount_amount, s.hotel_discount, s.hotel_discount_amount,
    s.flight_booked, s.hotel_booked, s.cancellation, u.birthdate, u.gender, u.married,
    u.has_children, u.home_country, u.home_city, u.home_airport, u.home_airport_lat,
    u.home_airport_lon, u.sign_up_date, f.origin_airport, f.destination, f.destination_airport,
    f.seats, f.return_flight_booked, f.departure_time, f.return_time, f.checked_bags,
    f.trip_airline, f.destination_airport_lat, f.destination_airport_lon, f.base_fare_usd,
    h.hotel_name, h.nights, h.rooms, h.check_in_time, h.check_out_time,
    h.hotel_per_room_usd AS hotel_per_room_night_usd,
    CASE
        WHEN nights < 0 THEN 0
        WHEN nights = 0 THEN 1
        ELSE nights
    END AS new_nights
FROM sessions s
LEFT JOIN users u ON s.user_id = u.user_id
LEFT JOIN flights f ON s.trip_id = f.trip_id
LEFT JOIN hotels h ON s.trip_id = h.trip_id
WHERE s.session_start >= '2023-01-04'
  AND s.user_id IN (SELECT user_id FROM filtered_users)),
 
cancelled_trips_cancellation_flag AS
(SELECT
    user_id, session_id, trip_id, cancellation, flight_booked, hotel_booked,
    check_in_time, check_out_time, return_time, return_flight_booked
FROM Cohort
WHERE cancellation = true AND trip_id IS NOT NULL),

 not_cancelled_trips AS
(SELECT *
FROM Cohort
WHERE trip_id NOT IN (SELECT trip_id FROM cancelled_trips_cancellation_flag) AND trip_id IS NOT NULL),

FINAL AS
(SELECT
    c.*,
    CASE
        WHEN DATE_PART('year', AGE(c.birthdate)) BETWEEN 18 AND 24 THEN '18-24'
        WHEN DATE_PART('year', AGE(c.birthdate)) BETWEEN 25 AND 34 THEN '25-34'
        WHEN DATE_PART('year', AGE(c.birthdate)) BETWEEN 35 AND 44 THEN '35-44'
        WHEN DATE_PART('year', AGE(c.birthdate)) BETWEEN 45 AND 54 THEN '45-54'
        WHEN DATE_PART('year', AGE(c.birthdate)) BETWEEN 55 AND 64 THEN '55-64'
        WHEN DATE_PART('year', AGE(c.birthdate)) >= 65 THEN '65+'
    END AS age_group,
    DATE_PART('year', AGE(CURRENT_DATE, sign_up_date)) * 12 +
    DATE_PART('month', AGE(CURRENT_DATE, sign_up_date)) AS customer_age_months_since_signup,
    EXTRACT(EPOCH FROM (session_end - session_start)) AS session_duration_seconds,
    AGE(return_time, departure_time) AS duration_stay_flight,
    CASE
        WHEN c.trip_id IN (SELECT trip_id FROM not_cancelled_trips) THEN 'completed_trip'
        WHEN c.trip_id IS NULL THEN 'Never_booked_trip'
        ELSE 'cancelled_trip'
    END AS trip_status
FROM Cohort c),
 user_overall_base AS(
SELECT
    user_id,
    ROUND(AVG(page_clicks)) AS avg_page_clicks,
    COUNT(session_id) AS num_sessions,
    ROUND(AVG(session_duration_seconds), 1) AS avg_session_duration_seconds,
    COUNT(DISTINCT trip_id) AS total_booked_trips,
    COUNT(DISTINCT CASE WHEN cancellation THEN trip_id END) AS num_cancelled_trips,
    COUNT(CASE WHEN trip_status = 'Never_booked_trip' THEN trip_status END) AS num_no_booking
FROM FINAL
GROUP BY user_id),

 user_comp_trip_base AS
(SELECT
    user_id,
    COUNT(DISTINCT trip_id) AS num_completed_trips,
    SUM(CASE WHEN flight_booked AND return_flight_booked THEN 1 END) AS num_round_trip_flights,
    SUM(CASE WHEN (flight_booked AND return_flight_booked != TRUE) OR (flight_booked != TRUE AND return_flight_booked) THEN 1 END) AS num_one_way_flights,
    SUM(CASE
        WHEN flight_booked AND return_flight_booked THEN 2
        WHEN (flight_booked AND return_flight_booked != TRUE) OR (flight_booked != TRUE AND return_flight_booked) THEN 1
        ELSE 0
    END) AS total_flights_booked,
    COUNT(DISTINCT CASE WHEN hotel_booked THEN trip_id END) AS total_hotels_booked,
    ROUND(AVG(flight_discount_amount), 2) AS avg_flight_discount_amount,
    ROUND(AVG(base_fare_usd), 2) AS avg_flight_base_price,
 ROUND(
              CASE WHEN COUNT(DISTINCT session_id) > 0 THEN 
  	      1.0 * COUNT(DISTINCT CASE WHEN NOT cancellation THEN trip_id END) / COUNT(DISTINCT session_id)
  	      ELSE 0 END
              ,2) AS conversion_rate,
    AVG(CASE
        WHEN (flight_booked OR return_flight_booked) AND flight_discount THEN base_fare_usd * seats * (1 - flight_discount_amount)
        WHEN (flight_booked OR return_flight_booked) AND flight_discount != TRUE THEN base_fare_usd * seats
    END) AS avg_flight_spent,
    AVG(CASE
        WHEN hotel_booked AND hotel_discount THEN hotel_per_room_night_usd * new_nights * rooms * (1 - hotel_discount_amount)
        WHEN hotel_booked AND hotel_discount != TRUE THEN hotel_per_room_night_usd * new_nights * rooms
    END) AS avg_hotel_spent,
    ROUND(AVG(hotel_discount_amount), 2) AS avg_hotel_discount_amount,
    ROUND(AVG(checked_bags)) AS avg_checked_bags,
    ROUND(AVG(seats)) AS avg_seats_booked,
    ROUND(AVG(rooms)) AS avg_rooms,
    ROUND(AVG(EXTRACT(EPOCH FROM (departure_time - session_end)) / 86400)) AS avg_days_until_departure,
    ROUND(AVG(EXTRACT(EPOCH FROM (check_in_time - session_end)) / 86400)) AS avg_days_until_checkin,
    ROUND(AVG(new_nights)) AS avg_night_stay_hotel,
    SUM(CASE WHEN home_airport = origin_airport THEN 1 ELSE 0 END) AS num_times_travelled_from_homeairport,
    SUM(CASE WHEN home_airport = destination_airport THEN 1 ELSE 0 END) AS num_times_travelled_to_homeairport,
    SUM(CASE WHEN home_airport != origin_airport THEN 1 ELSE 0 END) AS num_times_travelled_from_outside_homeairport,
    SUM(CASE WHEN hotel_per_room_night_usd > 300 THEN 1 ELSE 0 END) AS num_times_expensive_hotel_booked,
    SUM(CASE WHEN base_fare_usd > 5000 THEN 1 ELSE 0 END) AS num_times_expensive_flight_booked,
    ROUND(AVG(EXTRACT(EPOCH FROM (return_time - departure_time)) / 86400)) AS avg_days_stay_flight,
    AVG(haversine_distance(home_airport_lat,home_airport_lon,destination_airport_lat,destination_airport_lon)) AS avg_distance_flown,
    SUM(CASE WHEN (EXTRACT(DAY FROM departure_time) BETWEEN 5 and 6 AND EXTRACT(day FROM return_time) = 7 AND new_nights<=2) THEN 1 ELSE 0 END) AS num_weekend_trip,

    SUM(CASE WHEN (EXTRACT(MONTH FROM departure_time) BETWEEN 6 AND 8 OR EXTRACT(MONTH FROM departure_time) = 12)
             THEN 1
             ELSE 0
           END) AS num_holiday_season_trip

FROM not_cancelled_trips
GROUP BY user_id)

SELECT
    o.*,
    uc.num_completed_trips,
    uc.num_round_trip_flights,
    uc.num_one_way_flights,
    uc.total_flights_booked,
    uc.total_hotels_booked,
    uc.avg_flight_discount_amount,
    uc.avg_flight_base_price,
    uc.avg_flight_spent,
    uc.conversion_rate,
    uc.avg_hotel_spent,
    uc.avg_hotel_discount_amount,
    uc.avg_checked_bags,
    uc.avg_seats_booked,
    uc.avg_rooms,
    uc.avg_days_until_departure,
    uc.avg_days_until_checkin,
    uc.avg_days_stay_flight,
    uc.avg_night_stay_hotel,
    uc.num_times_travelled_from_homeairport,
    uc.num_times_travelled_to_homeairport,
    uc.num_times_travelled_from_outside_homeairport,
    uc.num_times_expensive_hotel_booked,
    uc.num_times_expensive_flight_booked,
    uc.num_weekend_trip,
    uc.num_holiday_season_trip,
    uc.avg_distance_flown,
    u.gender,
    u.married,
    u.has_children,
    u.home_country
    FROM user_overall_base o
LEFT JOIN user_comp_trip_base uc ON o.user_id = uc.user_id
LEFT JOIN users u ON o.user_id = u.user_id;











