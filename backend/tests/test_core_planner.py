import datetime as dt

import pytest
from fastapi import HTTPException

from app import core, main


@pytest.fixture(autouse=True)
def isolated_db(tmp_path, monkeypatch):
    monkeypatch.setattr(core, 'DB_PATH', tmp_path / 'test.db')
    core.init_core()
    from app.extra import init_extra
    init_extra()


def test_auth_course_isolation_and_logout():
    a = main.register(main.Credentials(username='alice',password='password'))
    b = main.register(main.Credentials(username='bob',password='password'))
    uid = a['user']['user_id']; other = b['user']['user_id']
    assert core.current_user('Bearer '+a['access_token']) == uid
    assert main.login(main.Credentials(username='alice',password='password'))['user']['user_id'] == uid
    with pytest.raises(HTTPException) as error:
        main.login(main.Credentials(username='alice',password='wrongpassword'))
    assert error.value.status_code == 401
    course = main.create_course(main.CourseInput(title='数学'), uid)
    with pytest.raises(HTTPException) as error:
        main.get_course(course['course_id'], other)
    assert error.value.status_code == 403
    main.add_member(course['course_id'], {'user_id':other}, uid)
    assert main.get_course(course['course_id'], other)['role'] == 'member'
    main.logout(uid, 'Bearer '+a['access_token'])
    with pytest.raises(HTTPException): core.current_user('Bearer '+a['access_token'])


def test_planner_completion_and_recommendation_dedup():
    uid = main.register(main.Credentials(username='alice',password='password'))['user']['user_id']
    day = dt.date(2026,11,6)
    course = main.create_course(main.CourseInput(title='数学', ddl=dt.date(2026,12,1), available_slots=[{'weekday':day.isoweekday(),'start':'19:00','end':'20:00'}]), uid)
    cid = course['course_id']
    result = main.auto_generate(cid, {'date':str(day)}, uid)
    assert len(result['items']) == 2
    assert result['items'][0]['planned_time_slot'] == '19:00'
    assert result['items'][1]['planned_time_slot'] == '19:25'
    assert len(main.auto_generate(cid, {'date':str(day)}, uid)['skipped']) == 2
    practice = result['items'][1]
    with pytest.raises(HTTPException) as error:
        main.complete(practice['task_id'], {'completion':'full'}, uid)
    assert error.value.status_code == 422
    lesson = result['items'][0]
    finished = main.complete(lesson['task_id'], {'completion':'full'}, uid)
    assert finished['status'] == 'done' and finished['completed_at']
    assert main.today(cid, day, uid)['summary']['done'] == 1


def test_points_today_uses_real_earn_transactions():
    from app.extra import transaction
    uid = main.register(main.Credentials(username='alice',password='password'))['user']['user_id']
    cid = main.create_course(main.CourseInput(title='数学'), uid)['course_id']
    with core.db() as con:
        transaction(con,uid,'earn',5,'practice','event','evt_1')
        transaction(con,uid,'spend',-2,'shop','exchange','item_1')
    assert main.today(cid, None, uid)['summary']['points_today'] == 5
