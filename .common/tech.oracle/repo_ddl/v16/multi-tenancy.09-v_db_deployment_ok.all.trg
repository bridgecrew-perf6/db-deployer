create or replace trigger trg_vdb_deployment_ok$iri
instead of insert on v_db_deployment_ok
declare
    l_increment_id                  t_db_increment.id_db_increment%type;
    l_script_id                     t_db_script.id_db_script%type;
    l_deployment_id                 t_db_deployment.id_db_deployment%type;
    l_script_exec_id                t_db_script_execution.id_db_script_execution%type;
    l_script_start                  t_db_script_execution.fip_start%type := systimestamp;
    l_script_exec_ret               t_db_script_execution.num_return_code%type;
    l_app_v_id                      t_db_app.app_v_id%type;
begin
    begin
        insert into t_db_app (app_id) values (:new.app_id);
    exception
         when dup_val_on_index then
             select app_v_id into l_app_v_id from t_db_app where app_id = :new.app_id for update;
    end;

    begin
        insert into t_db_increment (app_id, id_db_increment, txt_folder)
        values (seq_db_deployment.nextval, trim(:new.app_id), trim(:new.txt_folder))
        returning id_db_increment into l_increment_id;
    exception
        when dup_val_on_index then
            select id_db_increment
            into l_increment_id
            from t_db_increment I
            where I.txt_folder = trim(:new.txt_folder)
                and I.app_id = trim(:new.app_id)
            for update;
    end;

    begin
        insert into t_db_script (id_db_script, id_db_increment, txt_script_file)
        values (seq_db_deployment.nextval, l_increment_id, trim(:new.txt_script_file))
        returning id_db_script into l_script_id;
    exception
        when dup_val_on_index then
            select id_db_script
            into l_script_id
            from t_db_script F
            where F.id_db_increment = l_increment_id
                and F.txt_script_file = trim(:new.txt_script_file)
            for update nowait;
    end;

    begin
        select id_db_deployment, id_db_script_execution, num_return_code, app_v_id
        into l_deployment_id, l_script_exec_id, l_script_exec_ret, l_app_v_id
        from (
                select D.id_db_deployment, FX.id_db_script_execution, FX.num_return_code, FX.app_v_id
                from t_db_deployment D
                    left join t_db_script_execution FX
                        on FX.id_db_deployment = D.id_db_deployment
                        and FX.id_db_script = l_script_id
                        and exists (
                            select *
                            from t_db_app_v AV
                            where AV.app_id = :new.app_id
                                and AV.app_v_id = FX.app_v_id
                        )
                order by D.fip_create desc, D.id_db_deployment desc
            )
        where rownum <= 1;
    exception
        when no_data_found then
            l_deployment_id := null;
            l_script_exec_id := null;
            l_script_exec_ret := -1;
    end;

    if l_script_exec_ret != 0
        or l_script_exec_ret is null
    then
        if l_deployment_id is null
            or l_script_exec_id is not null
        then
            insert into t_db_deployment (id_db_deployment, app_id)
            values (seq_db_deployment.nextval, :new.app_id)
            returning id_db_deployment into l_deployment_id;
        end if;

        insert into t_db_script_execution (id_db_script_execution, id_db_deployment, id_db_script, num_order, fip_start, fip_finish, num_return_code, app_v_id)
        values (seq_db_deployment.nextval, l_deployment_id, l_script_id, seq_db_deployment.nextval, l_script_start, systimestamp, 0, l_app_v_id);
    end if;
end;
/
create or replace trigger trg_vdb_deployment_ok$ird
instead of delete on v_db_deployment_ok
declare
    type arr_increment_id           is table of t_db_increment.id_db_increment%type;
    l_increment_id                  arr_increment_id;
begin
    delete from t_db_script
    where txt_script_file = trim(:old.txt_script_file)
    returning id_db_increment bulk collect into l_increment_id;

    l_increment_id := set(l_increment_id);

    if sql%rowcount > 0 then
        forall i in indices of l_increment_id
            delete from t_db_increment I
            where I.id_db_increment = l_increment_id(i)
                and not exists (
                    select 1
                    from t_db_script F
                    where F.id_db_increment = I.id_db_increment
                );
    end if;
end;
/
