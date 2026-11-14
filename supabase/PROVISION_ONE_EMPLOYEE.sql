-- 1. First create the employee in Supabase Dashboard > Authentication > Users > Add user.
-- 2. Set a strong temporary password privately. Use an email you control / can recover.
-- 3. Replace the example email below with the exact employee Auth email.
-- 4. Change username and display name, and customize true/false permissions.
-- Never use the owner's email here. Never insert an employee into admin_users.
begin;
insert into public.staff_profiles(user_id,username,display_name,phone,is_active)
select id,'employee01','موظف 01',null,true from auth.users where lower(email)=lower('EMPLOYEE_EMAIL@example.com')
on conflict (user_id) do nothing;
insert into public.staff_permissions(user_id,can_add_products,can_edit_products,can_change_prices,can_delete_products,can_manage_categories,can_manage_stock,can_view_orders,can_manage_orders,can_manage_images)
select user_id,true,true,false,false,false,false,false,false,true
from public.staff_profiles where username='employee01'
on conflict (user_id) do nothing;
commit;
-- Check result; 0 rows means the Auth user wasn't found or username was not inserted.
select p.username,p.display_name,p.is_active,s.* from public.staff_profiles p
join public.staff_permissions s using(user_id) where p.username='employee01';
