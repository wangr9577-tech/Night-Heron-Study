import pytest
from fastapi import HTTPException
from app import core,main,demo_b

@pytest.fixture
def setup(tmp_path,monkeypatch):
    monkeypatch.setattr(core,'DB_PATH',tmp_path/'test.db')
    core.init_core(); demo_b.init_demo_b()

def test_demo_resources_are_course_scoped_and_flagged(setup):
    alice=main.register(main.Credentials(username='alice',password='password123'))['user']['user_id']
    bob=main.register(main.Credentials(username='bob',password='password123'))['user']['user_id']
    course=main.create_course(main.CourseInput(title='数学'),alice)['course_id']
    l=demo_b.lessons(course,alice); assert l['is_demo']
    lid=l['items'][0]['lesson_id']; assert demo_b.lesson_detail(lid,alice)['pages'][0]['explanation_segments']
    assert demo_b.graph(course,alice)['nodes'][0]['mastery'] is None
    assert demo_b.material_detail('mat_demo_'+course,alice)['pages']
    with pytest.raises(HTTPException) as error: demo_b.lesson_detail(lid,bob)
    assert error.value.status_code==403

def test_demo_quiz_never_changes_tasks_or_produces_events(setup):
    uid=main.register(main.Credentials(username='alice',password='password123'))['user']['user_id']
    cid=main.create_course(main.CourseInput(title='数学'),uid)['course_id']
    task=main.create_task(cid,main.TaskInput(type='practice',target_id='qst_demo_'+cid,title='练习',planned_date='2026-11-06'),uid)
    ans=demo_b.attempt(demo_b.AttemptInput(question_id='qst_demo_'+cid,course_id=cid,answer='3',source_task_id=task['task_id']),uid)
    assert ans['is_demo'] and ans['is_correct'] and demo_b.attempt_detail(ans['attempt_id'],uid)['score']==10
    assert main.task_detail(task['task_id'],uid)['status']=='pending'
    assert main.demo_events(course_id=cid,user=uid)['events']==[]
    assert '无法回答' in demo_b.ask(demo_b.Ask(course_id=cid,question='什么是数论？'),uid)['text']
