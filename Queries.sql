use DataWarehouseAnalytics;

select * from dbo.[gold.fact_sales];

/* Change Over Time */
/* 1. sales over years*/
select
year(order_date) as order_year,
sum(sales_amount) as total_sales from dbo.[gold.fact_sales]
where order_date is not null
group by year(order_date)
order by year(order_date);

/* 2. are we gaining customers over years or no */
select
year(order_date) as order_year,
sum(sales_amount) as total_sales,
count(distinct customer_key) as total_customers
from dbo.[gold.fact_sales]
where order_date is not null
group by year(order_date)
order by year(order_date);

/* 3. total quantity over months*/
select
month(order_date) as order_month,
sum(quantity) as total_quantity
from dbo.[gold.fact_sales]
where order_date is not null
group by month(order_date)
order by month(order_date);

/* formatting the date */
select
format(order_date, 'yyyy-MMM') as date,
sum(quantity) as total_quantity
from dbo.[gold.fact_sales]
where order_date is not null
group by format(order_date, 'yyyy-MMM')
order by format(order_date, 'yyyy-MMM');

/* Cumulative Analysis
	Running total of sales over time
*/
select
order_date,
total_sales,
sum(total_sales) over (order by order_date) as running_total_sales
from
(
select
datetrunc(year, order_date) as order_date,
sum(sales_amount) as total_sales
from dbo.[gold.fact_sales]
where order_date is not null
group by datetrunc(year, order_date)
) as t

/* Performance Analysis 
	1. Analyse the yearly performance of products by comparing their tables
	to the average sales performance of the product and the previous sales
*/

with yearly_product_sales as (
select 
year(f.order_date) as order_year,
p.product_name,
sum(f.sales_amount) as current_sales
from [gold.fact_sales] f
left join [gold.dim_products] p
on f.product_key = p.product_key
where order_date is not null
group by
year(f.order_date),
p.product_name
)

select 
order_year,
product_name,
current_sales,
avg(current_sales) over (partition by product_name) avg_sales,
current_sales - avg(current_sales) over (partition by product_name) as diff_avg,
CASE WHEN current_sales - avg(current_sales) over (partition by product_name) > 0 THEN 'Above Avg'
	WHEN current_sales - avg(current_sales) over (partition by product_name) < 0 THEN 'Below Avg'
	ELSE 'Avg'
END avg_change
from yearly_product_sales
order by product_name, order_year;

/* 2. Analyse the yearly performance of products by comparing their tables
	to the previous year sales performance of the product and the previous sales
*/

with yearly_product_sales as (
select 
year(f.order_date) as order_year,
p.product_name,
sum(f.sales_amount) as current_sales
from [gold.fact_sales] f
left join [gold.dim_products] p
on f.product_key = p.product_key
where order_date is not null
group by
year(f.order_date),
p.product_name
)

select 
order_year,
product_name,
current_sales,
LAG (current_sales) over (partition by product_name order by order_year) py_sales,
current_sales - LAG (current_sales) over (partition by product_name order by order_year) diff_sales,
CASE WHEN current_sales - LAG (current_sales) over (partition by product_name order by order_year) > 0 THEN 'Increase'
	WHEN current_sales - LAG (current_sales) over (partition by product_name order by order_year) < 0 THEN 'Decrease'
	ELSE 'No change'
END avg_change
from yearly_product_sales
order by product_name, order_year;

-- Proportional Analysis 
-- Which categories contribute the most to overall sales?
with category_sales as 
(
select
category,
sum(sales_amount) as total_sales
from dbo.[gold.fact_sales] f
left join [gold.dim_products] p
on p.product_key = f.product_key
group by category
)

select
category,
total_sales,
sum(total_sales) over () overall_sales,
concat(round((cast (total_sales as float) /sum(total_sales) over ())* 100 , 2), '%') as percentage_total
from category_sales
order by total_sales desc

-- Data segmentation
-- 1. Segment prdoucts into cost ranges and count how many products fall into segment
with product_segments as 
(
select
product_key,
product_name,
cost,
case when cost < 100 then 'Below 100'
	when cost between 100 and 500 then '100 and 500'
	when cost between 500 and 1000 then '500-1000'
	else 'Above 100'
	end cost_range
from dbo.[gold.dim_products]
)

select 
cost_range,
count(product_key) as total_products
from product_segments
group by cost_range
order by total_products desc

/* 2. Group customers into three segments based on their spending behavior:
- VIP: Customers with at least 12 months of history and spending more than 5000
- Regular: Customers with at least 12 months of history but spending 5000 or less
- New: Customers with a lifespan of less than 12 months.
And find the total number of customers by each group.
*/

with customer_spending as
(
select
c.customer_key,
sum(f.sales_amount) as total_spending,
min(order_date) as first_order,
max(order_date) as last_order,
datediff(month, min(order_date), max(order_date)) as lifespan
from dbo.[gold.fact_sales] f
left join [gold.dim_customers] c
on f.customer_key = c.customer_key
group by c.customer_key
)

select 
customer_segments,
count(customer_key) as total_customers
from
(
select
customer_key,
case when lifespan >= 12 and total_spending > 5000 then 'VIP'
when lifespan >= 12 and total_spending <= 5000 then 'Regular'
else 'New'
end customer_segments
from customer_spending 
) t
group by customer_segments
order by total_customers desc

/* 
----------------------------
Customer report
-----------------------------
Purpose: This report consolidates key customer metrics and behaviours

Highlights:
- Gathers essential fields such as names, ages and transaction details.
- Segments customers into categories (VIO, Regular, New) and age groups.
- Aggregates customer level metrics
total orders, total sales, total quantity purchased, total products and lifespan in months
- Calculated valuable KPIs
recency(months since last order), average order value and average monthly spend
-------------------------------------
*/

with base_query as 
(
/*
1. Base query: Retrieve core columns from the table
*/
select
f.order_number,
f.product_key,
f.order_date,
f.sales_amount,
f.quantity,
c.customer_key,
c.customer_number,
c.first_name,
c.last_name,
concat(c.first_name, ' ',c.last_name) as customer_name,
datediff(year,c.birthdate,getdate()) age
from dbo.[gold.fact_sales] f
left join dbo.[gold.dim_customers] c
on c.customer_key = f.customer_key
where order_date is not null
),
customer_aggregation as
(
/*--------------------------------------
Customer Aggregations: Summarizes key metrics at the customer level
-----------------------------------------*/

select 
customer_key,
customer_number,
customer_name,
age,
count(distinct order_number) as total_orders,
sum(sales_amount) as total_sales,
sum(quantity) as total_quantity,
count(distinct product_key) as total_products,
max(order_date) as last_order,
datediff(month,min(order_date), max(order_date)) as lifespan
from base_query
group by customer_key,
customer_number,
customer_name,
age
)
select 
customer_key,
customer_number,
customer_name,
age,
case when age < 20 then 'under 20'
when age between 20 and 29 then '20-29'
when age between 30 and 39 then '30-39'
when age between 40 and 49 then '40-49'
else '50 and above'
end as age_group,
total_orders,
case when lifespan >= 12 and total_sales > 5000 then 'VIP'
when lifespan >= 12 and total_sales <= 5000 then 'Regular'
else 'New'
end customer_segments,
last_order,
datediff(month,last_order,getdate()) as recency,
total_sales,
total_quantity,
total_products,
lifespan,

---Compuate average order value
case when total_orders = 0 then 0
else total_sales/total_orders 
end as avg_order_value,

--Compute average monthly spend
case when lifespan = 0 then total_sales
else total_sales/lifespan
end as avg_monthly_spend
from customer_aggregation
