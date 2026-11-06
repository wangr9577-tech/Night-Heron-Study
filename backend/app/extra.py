"""Companion, rewards, speech and notification endpoints owned by A."""
import io
import json
import math
import os
import struct
import wave
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form, Header
from fastapi.responses import Response
from pydantic import BaseModel, Field
from app.core import db, current_user, new_id, now

router = APIRouter(prefix='/api/v1')


def init_extra():
    with db() as c:
        c.executescript('''
        CREATE TABLE IF NOT EXISTS pets (pet_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,name TEXT NOT NULL,avatar_key TEXT NOT NULL,personality TEXT NOT NULL,growth TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS pet_messages (message_id TEXT PRIMARY KEY,pet_id TEXT NOT NULL,role TEXT NOT NULL,content TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS pet_memories (memory_id TEXT PRIMARY KEY,pet_id TEXT NOT NULL,content TEXT NOT NULL,source TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS growth_events (event_id TEXT PRIMARY KEY,pet_id TEXT NOT NULL,type TEXT NOT NULL,exp_delta INTEGER NOT NULL,at TEXT NOT NULL,ref_id TEXT);
        CREATE TABLE IF NOT EXISTS balances (user_id TEXT PRIMARY KEY,balance INTEGER NOT NULL DEFAULT 0,updated_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS transactions (tx_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,type TEXT NOT NULL,amount INTEGER NOT NULL,balance_after INTEGER NOT NULL,reason TEXT NOT NULL,ref_type TEXT,ref_id TEXT,at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS bag (user_id TEXT NOT NULL,item_id TEXT NOT NULL,qty INTEGER NOT NULL,last_used_at TEXT,PRIMARY KEY(user_id,item_id));
        CREATE TABLE IF NOT EXISTS consumed_events (event_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,consumed_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS event_cursors (user_id TEXT NOT NULL,course_scope TEXT NOT NULL,cursor TEXT,updated_at TEXT NOT NULL,PRIMARY KEY(user_id,course_scope));
        CREATE TABLE IF NOT EXISTS audio_cache (audio_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,cache_key TEXT NOT NULL,text TEXT NOT NULL,voice TEXT NOT NULL,data BLOB NOT NULL,duration_ms INTEGER NOT NULL,UNIQUE(user_id,cache_key,text,voice));
        CREATE TABLE IF NOT EXISTS oral_sessions (session_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,scene_id TEXT NOT NULL,created_at TEXT NOT NULL,finished INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS oral_turns (turn_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,user_text TEXT NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS notifications (ntf_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,type TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,ref_type TEXT,ref_id TEXT,created_at TEXT NOT NULL,read_at TEXT);
        CREATE TABLE IF NOT EXISTS notification_settings (user_id TEXT PRIMARY KEY,settings TEXT NOT NULL);
        ''')

class PetInput(BaseModel):
    name: str = Field(default='小啄', min_length=1, max_length=50)
    avatar_key: str = 'bird_1'
    personality: dict = Field(default_factory=lambda: {'tone':'鼓励型','verbosity':'简洁'})
class PetPatch(BaseModel):
    name: str | None = Field(default=None,min_length=1,max_length=50)
    avatar_key: str | None = None
    personality: dict | None = None
class Content(BaseModel):
    content: str = Field(min_length=1,max_length=2000)
class Exchange(BaseModel):
    item_id: str
    qty: int = Field(default=1,ge=1,le=100)
class Feed(BaseModel):
    pet_id: str
    item_id: str

SHOP = [{'item_id':'itm_apple','name':'苹果','kind':'food','price':10,'icon_key':'apple','desc':'给小啄的水果'}, {'item_id':'itm_seed','name':'谷粒','kind':'food','price':5,'icon_key':'seed','desc':'小啄喜欢的谷粒'}]

def pet_out(row):
    p=dict(row); p['personality']=json.loads(p['personality']); p['growth']=json.loads(p['growth']); return p

def owned_pet(c, uid, pet_id):
    p=c.execute('SELECT * FROM pets WHERE pet_id=? AND user_id=?',(pet_id,uid)).fetchone()
    if p is None: raise HTTPException(404, 'pet not found')
    return p

def balance(c, uid):
    c.execute('INSERT OR IGNORE INTO balances VALUES (?,0,?)',(uid,now()))
    return c.execute('SELECT balance FROM balances WHERE user_id=?',(uid,)).fetchone()[0]

def transaction(c,uid,kind,amount,reason,ref_type,ref_id):
    value=balance(c,uid)+amount
    if value<0: raise HTTPException(422,'insufficient points')
    t={'tx_id':new_id('tx'),'user_id':uid,'type':kind,'amount':amount,'balance_after':value,'reason':reason,'ref_type':ref_type,'ref_id':ref_id,'at':now()}
    c.execute('UPDATE balances SET balance=?,updated_at=? WHERE user_id=?',(value,t['at'],uid))
    c.execute('INSERT INTO transactions VALUES (?,?,?,?,?,?,?,?,?)',tuple(t.values()))
    return t

@router.get('/companion/pets')
def list_pets(uid: str=Depends(current_user)):
    with db() as c: return {'items':[pet_out(p) for p in c.execute('SELECT * FROM pets WHERE user_id=?',(uid,))]}
@router.post('/companion/pets')
def create_pet(body: PetInput,uid: str=Depends(current_user)):
    p={'pet_id':new_id('pet'),'user_id':uid,'name':body.name,'avatar_key':body.avatar_key,'personality':json.dumps(body.personality,ensure_ascii=False),'growth':json.dumps({'level':1,'exp':0,'streak_days':0,'total_minutes':0}),'created_at':now()}
    with db() as c: c.execute('INSERT INTO pets VALUES (?,?,?,?,?,?,?)',tuple(p.values()))
    return pet_out(p)
@router.get('/companion/pets/{pet_id}')
def get_pet(pet_id: str,uid: str=Depends(current_user)):
    with db() as c: return pet_out(owned_pet(c,uid,pet_id))
@router.patch('/companion/pets/{pet_id}')
def patch_pet(pet_id: str,body: PetPatch,uid: str=Depends(current_user)):
    with db() as c:
        p=pet_out(owned_pet(c,uid,pet_id)); changes=body.model_dump(exclude_none=True)
        p.update(changes); c.execute('UPDATE pets SET name=?,avatar_key=?,personality=? WHERE pet_id=?',(p['name'],p['avatar_key'],json.dumps(p['personality'],ensure_ascii=False),pet_id)); return p
@router.get('/companion/pets/{pet_id}/chat')
def messages(pet_id: str,limit: int=50,before: str|None=None,uid: str=Depends(current_user)):
    with db() as c:
        owned_pet(c,uid,pet_id)
        rows=c.execute('SELECT * FROM pet_messages WHERE pet_id=? AND (? IS NULL OR created_at<?) ORDER BY created_at DESC LIMIT ?',(pet_id,before,before,max(1,min(limit,200)))).fetchall()
        return {'items':[dict(x) for x in reversed(rows)]}
@router.post('/companion/pets/{pet_id}/chat')
def chat(pet_id: str,body: Content,uid: str=Depends(current_user)):
    with db() as c:
        pet=owned_pet(c,uid,pet_id); stamp=now()
        c.execute('INSERT INTO pet_messages VALUES (?,?,?,?,?)',(new_id('msg'),pet_id,'user',body.content,stamp))
        reply={'message_id':new_id('msg'),'pet_id':pet_id,'role':'pet','content':f"{pet['name']}陪你一起学习，先从一个小目标开始吧！",'created_at':now()}
        c.execute('INSERT INTO pet_messages VALUES (?,?,?,?,?)',tuple(reply.values()))
        return {'reply':reply,'ref_type':None,'ref_id':None,'is_demo':True,'notice':'演示回复，未接入 AI 对话'}
@router.get('/companion/pets/{pet_id}/memories')
def memories(pet_id: str,uid: str=Depends(current_user)):
    with db() as c: owned_pet(c,uid,pet_id); return {'items':[dict(x) for x in c.execute('SELECT * FROM pet_memories WHERE pet_id=?',(pet_id,))]}
@router.post('/companion/pets/{pet_id}/memories')
def add_memory(pet_id: str,body: Content,uid: str=Depends(current_user)):
    m={'memory_id':new_id('mem'),'pet_id':pet_id,'content':body.content,'source':'system','created_at':now()}
    with db() as c: owned_pet(c,uid,pet_id); c.execute('INSERT INTO pet_memories VALUES (?,?,?,?,?)',tuple(m.values())); return m
@router.patch('/companion/pets/{pet_id}/memories/{memory_id}')
def edit_memory(pet_id: str,memory_id: str,body: Content,uid: str=Depends(current_user)):
    with db() as c:
        owned_pet(c,uid,pet_id)
        if not c.execute('UPDATE pet_memories SET content=? WHERE memory_id=? AND pet_id=?',(body.content,memory_id,pet_id)).rowcount: raise HTTPException(404,'memory not found')
        return dict(c.execute('SELECT * FROM pet_memories WHERE memory_id=?',(memory_id,)).fetchone())
@router.delete('/companion/pets/{pet_id}/memories/{memory_id}')
def delete_memory(pet_id: str,memory_id: str,uid: str=Depends(current_user)):
    with db() as c:
        owned_pet(c,uid,pet_id)
        if not c.execute('DELETE FROM pet_memories WHERE memory_id=? AND pet_id=?',(memory_id,pet_id)).rowcount: raise HTTPException(404,'memory not found')
        return {'ok':True}
@router.get('/companion/pets/{pet_id}/growth-events')
def growth_events(pet_id: str,uid: str=Depends(current_user)):
    with db() as c: owned_pet(c,uid,pet_id); return {'items':[dict(x) for x in c.execute('SELECT * FROM growth_events WHERE pet_id=? ORDER BY at DESC',(pet_id,))]}
@router.get('/rewards/points')
def points(uid: str=Depends(current_user)):
    with db() as c:
        balance(c,uid); return dict(c.execute('SELECT balance,updated_at FROM balances WHERE user_id=?',(uid,)).fetchone())
@router.get('/rewards/transactions')
def transactions(month: str|None=None,uid: str=Depends(current_user)):
    with db() as c: return {'items':[dict(x) for x in c.execute('SELECT * FROM transactions WHERE user_id=? AND (? IS NULL OR substr(at,1,7)=?) ORDER BY at DESC',(uid,month,month))]}
@router.get('/rewards/shop')
def shop(uid: str=Depends(current_user)): return {'items':SHOP}
@router.get('/rewards/bag')
def get_bag(uid: str=Depends(current_user)):
    with db() as c: return {'items':[dict(x) for x in c.execute('SELECT item_id,qty,last_used_at FROM bag WHERE user_id=? AND qty>0',(uid,))]}
@router.post('/rewards/exchange')
def exchange(body: Exchange,uid: str=Depends(current_user)):
    item=next((x for x in SHOP if x['item_id']==body.item_id),None)
    if not item: raise HTTPException(404,'item not found')
    with db() as c:
        t=transaction(c,uid,'spend',-item['price']*body.qty,'兑换 '+item['name'],'exchange',body.item_id)
        c.execute('INSERT INTO bag VALUES (?,?,?,NULL) ON CONFLICT(user_id,item_id) DO UPDATE SET qty=qty+excluded.qty',(uid,body.item_id,body.qty))
        return {'tx':t,'bag_item':dict(c.execute('SELECT item_id,qty,last_used_at FROM bag WHERE user_id=? AND item_id=?',(uid,body.item_id)).fetchone())}
@router.post('/rewards/feed')
def feed(body: Feed,uid: str=Depends(current_user)):
    item=next((x for x in SHOP if x['item_id']==body.item_id and x['kind']=='food'),None)
    if not item: raise HTTPException(404,'food not found')
    with db() as c:
        p=pet_out(owned_pet(c,uid,body.pet_id))
        if not c.execute('UPDATE bag SET qty=qty-1,last_used_at=? WHERE user_id=? AND item_id=? AND qty>0',(now(),uid,body.item_id)).rowcount: raise HTTPException(422,'food unavailable')
        p['growth']['exp']+=5; p['growth']['level']=1+p['growth']['exp']//100
        c.execute('UPDATE pets SET growth=? WHERE pet_id=?',(json.dumps(p['growth']),body.pet_id))
        e={'event_id':new_id('evt'),'pet_id':body.pet_id,'type':'feed','exp_delta':5,'at':now(),'ref_id':body.item_id}
        c.execute('INSERT INTO growth_events VALUES (?,?,?,?,?,?)',tuple(e.values()))
        return {'pet':p,'tx':None,'bag_item':dict(c.execute('SELECT item_id,qty,last_used_at FROM bag WHERE user_id=? AND item_id=?',(uid,body.item_id)).fetchone()),'growth_event':e,'reaction_text':'真好吃，谢谢你！'}

class TTSRequest(BaseModel):
    text: str = Field(min_length=1,max_length=5000)
    voice: str = 'default'
    cache_key: str | None = None
class Segment(BaseModel):
    segment_id: str
    text: str = Field(min_length=1,max_length=5000)
class Batch(BaseModel):
    segments: list[Segment] = Field(max_length=100)
    voice: str = 'default'
class SessionInput(BaseModel):
    scene_id: str
    course_id: str | None = None
class TurnInput(BaseModel):
    transcript: str = Field(min_length=1,max_length=2000)
SCENES=[{'scene_id':'scene_greeting','title':'自我介绍','level':'基础','opening_text':'Hello! Please introduce yourself.','target_turns':3},{'scene_id':'scene_school','title':'校园生活','level':'基础','opening_text':'What do you like at school?','target_turns':3},{'scene_id':'scene_future','title':'未来计划','level':'进阶','opening_text':'What are your plans for the future?','target_turns':4}]

def synth(c,uid,text,voice,key):
    key=key or ''
    row=c.execute('SELECT * FROM audio_cache WHERE user_id=? AND cache_key=? AND text=? AND voice=?',(uid,key,text,voice)).fetchone()
    if row: return {'audio_id':row['audio_id'],'url':'/api/v1/speech/audio/'+row['audio_id'],'cache_hit':True,'duration_ms':row['duration_ms'],'is_demo':True,'notice':'演示提示音，不是语音合成'}
    if os.getenv('ZHI_TTS_PROVIDER','mock')!='mock': raise HTTPException(503,'TTS provider unavailable')
    # Deliberately a short audible placeholder, not synthesized speech.
    rate=16000; duration=400; out=io.BytesIO()
    with wave.open(out,'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(rate)
        wav.writeframes(b''.join(struct.pack('<h',int(3000*math.sin(2*math.pi*440*n/rate))) for n in range(rate*duration//1000)))
    aid=new_id('aud'); c.execute('INSERT INTO audio_cache VALUES (?,?,?,?,?,?,?)',(aid,uid,key,text,voice,out.getvalue(),duration))
    return {'audio_id':aid,'url':'/api/v1/speech/audio/'+aid,'cache_hit':False,'duration_ms':duration,'is_demo':True,'notice':'演示提示音，不是语音合成'}
@router.post('/speech/tts')
def tts(body: TTSRequest,uid: str=Depends(current_user)):
    with db() as c: return synth(c,uid,body.text,body.voice,body.cache_key)
@router.post('/speech/tts/batch')
def tts_batch(body: Batch,uid: str=Depends(current_user)):
    with db() as c: return {'items':[{'segment_id':s.segment_id,**synth(c,uid,s.text,body.voice,s.segment_id)} for s in body.segments]}
@router.get('/speech/audio/{audio_id}')
def audio(audio_id: str,uid: str=Depends(current_user)):
    with db() as c:
        row=c.execute('SELECT data FROM audio_cache WHERE audio_id=? AND user_id=?',(audio_id,uid)).fetchone()
        if not row: raise HTTPException(404,'audio not found')
        return Response(content=row['data'],media_type='audio/wav')
@router.post('/speech/asr')
async def asr(file: UploadFile=File(...),uid: str=Depends(current_user)):
    raise HTTPException(503,'ASR provider unavailable; please enter transcription manually')
@router.get('/speech/oral/scenes')
def scenes(uid: str=Depends(current_user)): return {'items':SCENES,'is_demo':True,'notice':'演示场景，尚未接入语音识别和智能对话'}
@router.post('/speech/oral/sessions')
def create_session(body: SessionInput,uid: str=Depends(current_user)):
    scene=next((x for x in SCENES if x['scene_id']==body.scene_id),None)
    if not scene: raise HTTPException(404,'scene not found')
    with db() as c:
        if body.course_id:
            from app.core import require_course
            require_course(c,uid,body.course_id)
        s={'session_id':new_id('oral'),'user_id':uid,'scene_id':body.scene_id,'created_at':now(),'finished':0}
        c.execute('INSERT INTO oral_sessions VALUES (?,?,?,?,?)',tuple(s.values()))
        return {'session':s,'opening':{'text':scene['opening_text'],'audio_id':None},'is_demo':True,'notice':'演示对话，回复和反馈为固定模板'}
def get_session(c,uid,session_id):
    s=c.execute('SELECT * FROM oral_sessions WHERE session_id=? AND user_id=?',(session_id,uid)).fetchone()
    if not s: raise HTTPException(404,'session not found')
    return s
@router.post('/speech/oral/sessions/{session_id}/turn')
def oral_turn(session_id: str,body: TurnInput,uid: str=Depends(current_user)):
    with db() as c:
        s=get_session(c,uid,session_id)
        if s['finished']: raise HTTPException(409,'session finished')
        tid=new_id('turn'); c.execute('INSERT INTO oral_turns VALUES (?,?,?,?)',(tid,session_id,body.transcript,now()))
        count=c.execute('SELECT COUNT(*) FROM oral_turns WHERE session_id=?',(session_id,)).fetchone()[0]
        target=next(x['target_turns'] for x in SCENES if x['scene_id']==s['scene_id'])
        return {'turn':{'turn_id':tid,'user_text':body.transcript,'corrected_text':body.transcript,'reply_text':'Thank you for sharing. Could you tell me more?','reply_audio_id':None,'feedback':{'expression_tips':['尝试用完整句子表达。'],'grammar_fix':None}},'finished':count>=target,'is_demo':True,'notice':'演示对话，回复和反馈为固定模板'}
@router.post('/speech/oral/sessions/{session_id}/finish')
def finish(session_id: str,uid: str=Depends(current_user)):
    with db() as c:
        s=get_session(c,uid,session_id); c.execute('UPDATE oral_sessions SET finished=1 WHERE session_id=?',(session_id,))
        count=c.execute('SELECT COUNT(*) FROM oral_turns WHERE session_id=?',(session_id,)).fetchone()[0]
        try: seconds=max(0,int((datetime.now(timezone.utc)-datetime.fromisoformat(s['created_at'].replace('Z','+00:00'))).total_seconds()))
        except (ValueError,TypeError): seconds=0
        return {'summary':{'turns':count,'total_seconds':seconds,'tips':['继续练习完整表达。']},'is_demo':True,'notice':'演示反馈，未进行智能评估'}

DEFAULT_SETTINGS={'in_app_enabled':True,'channels':{'wechat':{'enabled':False,'template_id':None}},'dnd':{'start':'23:00','end':'07:00'},'max_per_day':5,'ddl_remind_hours':24}
class NotificationPatch(BaseModel):
    in_app_enabled: bool | None = None
    channels: dict | None = None
    dnd: dict | None = None
    max_per_day: int | None = Field(default=None,ge=0,le=100)
    ddl_remind_hours: int | None = Field(default=None,ge=0,le=8760)
class GenerateRequest(BaseModel):
    date: str
@router.get('/notifications/settings')
def settings(uid: str=Depends(current_user)):
    with db() as c:
        row=c.execute('SELECT settings FROM notification_settings WHERE user_id=?',(uid,)).fetchone()
        return json.loads(row['settings']) if row else DEFAULT_SETTINGS.copy()
@router.patch('/notifications/settings')
def update_settings(body: NotificationPatch,uid: str=Depends(current_user)):
    if body.dnd is not None:
        import re
        if set(body.dnd) != {'start','end'} or any(not isinstance(v,str) or not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d',v) for v in body.dnd.values()):
            raise HTTPException(400,'invalid quiet hours')
    with db() as c:
        row=c.execute('SELECT settings FROM notification_settings WHERE user_id=?',(uid,)).fetchone()
        data=json.loads(row['settings']) if row else DEFAULT_SETTINGS.copy(); data.update(body.model_dump(exclude_none=True))
        c.execute('INSERT INTO notification_settings VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET settings=excluded.settings',(uid,json.dumps(data,ensure_ascii=False))); return data
@router.get('/notifications')
def notifications(unread_only: bool=False,cursor: str|None=None,uid: str=Depends(current_user)):
    with db() as c:
        rows=c.execute('SELECT * FROM notifications WHERE user_id=? AND (?=0 OR read_at IS NULL) AND (? IS NULL OR created_at<?) ORDER BY created_at DESC LIMIT 50',(uid,unread_only,cursor,cursor)).fetchall()
        return {'items':[dict(x) for x in rows],'next_cursor':rows[-1]['created_at'] if len(rows)==50 else None}
@router.post('/notifications/read-all')
def read_all(uid: str=Depends(current_user)):
    with db() as c: c.execute('UPDATE notifications SET read_at=? WHERE user_id=? AND read_at IS NULL',(now(),uid)); return {'ok':True}
@router.post('/notifications/{ntf_id}/read')
def read_notification(ntf_id: str,uid: str=Depends(current_user)):
    with db() as c:
        if not c.execute('UPDATE notifications SET read_at=COALESCE(read_at,?) WHERE ntf_id=? AND user_id=?',(now(),ntf_id,uid)).rowcount: raise HTTPException(404,'notification not found')
        return dict(c.execute('SELECT * FROM notifications WHERE ntf_id=?',(ntf_id,)).fetchone())
@router.post('/notifications/generate')
def generate_notifications(body: GenerateRequest,uid: str=Depends(current_user)):
    today=datetime.now(LOCAL_TZ).date().isoformat()
    if body.date != today: raise HTTPException(400,'only today can be generated')
    return {'items':generate_due_notifications(uid)}


class ConsumeRequest(BaseModel):
    course_id: str | None = None

def consume_verified_events(c, uid, events):
    """Consume only records retrieved by a trusted B adapter, inside the caller's transaction."""
    awarded=[]; consumed=0
    for event in events:
        if event.get('user_id')!=uid or not event.get('event_id') or not event.get('course_id'):
            raise ValueError('invalid event identity')
        from app.core import require_course
        require_course(c,uid,event['course_id'])
        if c.execute('SELECT 1 FROM consumed_events WHERE event_id=?',(event['event_id'],)).fetchone(): continue
        kind=event.get('event_type'); amount=0
        if kind=='practice_graded' and event.get('result',{}).get('passed') is True:
            today=now()[:10]
            earned=c.execute("SELECT COALESCE(SUM(amount),0) FROM transactions WHERE user_id=? AND reason='practice_graded' AND substr(at,1,10)=?",(uid,today)).fetchone()[0]
            amount=max(0,min(5,50-earned))
        elif kind=='task_criteria_met':
            task_id=event.get('source_task_id')
            row=c.execute('SELECT data FROM tasks WHERE task_id=? AND user_id=? AND course_id=?',(task_id,uid,event['course_id'])).fetchone()
            if not row: raise ValueError('event references missing task')
            task=json.loads(row['data'])
            if task['type'] not in ('practice','exam','mistake'): raise ValueError('event references wrong task type')
            if task['status'] not in ('done','cancelled'):
                task['status']='done'; task['completed_at']=now(); task['progress_percent']=100
                c.execute('UPDATE tasks SET data=? WHERE task_id=? AND user_id=?',(json.dumps(task,ensure_ascii=False),task_id,uid)); amount=20
        if amount: transaction(c,uid,'earn',amount,kind,'event',event['event_id']); awarded.append({'event_id':event['event_id'],'points':amount})
        c.execute('INSERT INTO consumed_events VALUES (?,?,?)',(event['event_id'],uid,now())); consumed+=1
    return {'consumed':consumed,'awarded':awarded}

@router.post('/rewards/consume-events')
def consume_events(body: ConsumeRequest,uid: str=Depends(current_user), authorization: str=Header()):
    from app.core import require_course
    from app.event_feed import read_events, FeedError
    scope = body.course_id or ''
    with db() as c:
        if scope: require_course(c,uid,scope)
        row=c.execute('SELECT cursor FROM event_cursors WHERE user_id=? AND course_scope=?',(uid,scope)).fetchone()
        cursor=row['cursor'] if row else None
    try:
        events,next_cursor=read_events(authorization[7:],body.course_id,cursor)
    except FeedError as exc:
        raise HTTPException(503,str(exc)) from exc
    try:
        with db() as c:
            c.execute('BEGIN IMMEDIATE')
            if scope: require_course(c,uid,scope)
            row=c.execute('SELECT cursor FROM event_cursors WHERE user_id=? AND course_scope=?',(uid,scope)).fetchone()
            if (row['cursor'] if row else None)!=cursor: raise HTTPException(409,'event cursor changed; retry')
            if any(e.get('course_id')!=scope for e in events) and scope: raise ValueError('event course mismatch')
            result=consume_verified_events(c,uid,events)
            # A null next cursor denotes the end, not a durable high-water mark.
            # Retain the last requested cursor and safely re-read the last page.
            checkpoint=next_cursor if next_cursor is not None else cursor
            c.execute('INSERT INTO event_cursors VALUES (?,?,?,?) ON CONFLICT(user_id,course_scope) DO UPDATE SET cursor=excluded.cursor,updated_at=excluded.updated_at',(uid,scope,checkpoint,now()))
            return {**result,'has_more':next_cursor is not None}
    except ValueError as exc:
        raise HTTPException(502,'invalid learning events') from exc

from datetime import timedelta
import threading

# The app currently operates in China time for calendar and quiet-hour decisions.
LOCAL_TZ = timezone(timedelta(hours=8))

def _notification_tables(c):
    c.execute('CREATE TABLE IF NOT EXISTS notification_keys (user_id TEXT NOT NULL, local_date TEXT NOT NULL, kind TEXT NOT NULL, ref_id TEXT NOT NULL, PRIMARY KEY(user_id,local_date,kind,ref_id))')

def generate_due_notifications(uid, local_now=None):
    local_now=local_now or datetime.now(LOCAL_TZ)
    day=local_now.date().isoformat(); hm=local_now.strftime('%H:%M')
    with db() as c:
        _notification_tables(c)
        row=c.execute('SELECT settings FROM notification_settings WHERE user_id=?',(uid,)).fetchone()
        cfg=json.loads(row['settings']) if row else DEFAULT_SETTINGS
        if not cfg.get('in_app_enabled',True): return []
        dnd=cfg.get('dnd') or {}; start=dnd.get('start','23:00'); end=dnd.get('end','07:00')
        if start != end and (start<=hm<end if start<end else hm>=start or hm<end): return []
        count=c.execute('SELECT COUNT(*) FROM notification_keys WHERE user_id=? AND local_date=?',(uid,day)).fetchone()[0]
        candidates=[]
        for row in c.execute('SELECT t.data FROM tasks t JOIN members m ON m.course_id=t.course_id AND m.user_id=t.user_id WHERE t.user_id=?',(uid,)):
            task=json.loads(row['data'])
            if task.get('planned_date')==day and task.get('status') not in ('done','cancelled'):
                candidates.append(('task_due','今日学习任务',task.get('title','学习任务'),'task',task['task_id']))
        courses=c.execute('SELECT c.data FROM courses c JOIN members m ON c.course_id=m.course_id WHERE m.user_id=?',(uid,)).fetchall()
        for row in courses:
            course=json.loads(row['data']); deadline=course.get('ddl')
            if not deadline or course.get('archived'): continue
            try:
                deadline_dt=datetime.fromisoformat(deadline+'T23:59:59').replace(tzinfo=LOCAL_TZ)
            except ValueError: continue
            hours=(deadline_dt-local_now).total_seconds()/3600
            if 0<=hours<=cfg.get('ddl_remind_hours',24):
                candidates.append(('ddl','课程截止提醒',f"{course.get('title','课程')} 将于 {deadline} 截止",'course',course['course_id']))
        created=[]
        for kind,title,body,ref_type,ref_id in candidates:
            if count+len(created)>=cfg.get('max_per_day',5): break
            if not c.execute('INSERT OR IGNORE INTO notification_keys VALUES (?,?,?,?)',(uid,day,kind,ref_id)).rowcount: continue
            n={'ntf_id':new_id('ntf'),'user_id':uid,'type':kind,'title':title,'body':body,'ref_type':ref_type,'ref_id':ref_id,'created_at':now(),'read_at':None}
            c.execute('INSERT INTO notifications VALUES (?,?,?,?,?,?,?,?,?)',tuple(n.values())); created.append(n)
        return created

def start_notification_scheduler(app):
    stop=threading.Event()
    def worker():
        while not stop.is_set():
            try:
                with db() as c: users=[r['user_id'] for r in c.execute('SELECT user_id FROM users')]
                for uid in users:
                    if stop.is_set(): break
                    generate_due_notifications(uid)
            except Exception:
                import logging
                logging.getLogger(__name__).exception('notification scheduler failed')
            stop.wait(60)
    @app.on_event('startup')
    def start():
        stop.clear(); app.state.notification_thread=threading.Thread(target=worker,name='zhi-notifications',daemon=True); app.state.notification_thread.start()
    @app.on_event('shutdown')
    def shutdown():
        stop.set()
        thread=getattr(app.state,'notification_thread',None)
        if thread: thread.join(timeout=2)
