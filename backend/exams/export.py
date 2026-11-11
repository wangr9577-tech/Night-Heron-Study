import os
from html import escape
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import KeepTogether, Paragraph, SimpleDocTemplate, Spacer


def pdf_font():
    font = "ZhuozhiPDF"
    if font in pdfmetrics.getRegisteredFontNames():
        return font
    path = Path(os.getenv("ZHUOZHI_PDF_FONT", "C:/Windows/Fonts/msyh.ttc"))
    if path.is_file():
        pdfmetrics.registerFont(TTFont(font, str(path), subfontIndex=0))
        return font
    font = "STSong-Light"
    if font not in pdfmetrics.getRegisteredFontNames():
        pdfmetrics.registerFont(UnicodeCIDFont(font))
    return font


def render_exam(title, items, questions, path, answers=False):
    """A4 export with explicit line heights and whole-question pagination."""
    font = pdf_font()
    body = ParagraphStyle(
        "body",
        fontName=font,
        fontSize=10.5,
        leading=18,
        spaceAfter=8,
        textColor=colors.HexColor("#172c34"),
        wordWrap="CJK",
        alignment=TA_LEFT,
    )
    heading = ParagraphStyle(
        "title", parent=body, fontSize=20, leading=28, spaceAfter=14, textColor=colors.HexColor("#183f46")
    )
    number = ParagraphStyle("number", parent=body, fontSize=12, leading=20, spaceBefore=10, spaceAfter=8)
    source = ParagraphStyle("source", parent=body, fontSize=8.5, leading=14, spaceAfter=10)

    def p(value, style=body):
        return Paragraph(escape(str(value)).replace("\n", "<br/>"), style)

    flow = [
        p(title, heading),
        p("参考答案与评分要点" if answers else "姓名：____________　日期：____________"),
        Spacer(1, 6),
    ]
    for index, item in enumerate(items):
        q = questions[item["question_id"]]
        block = [p(f"{index + 1}. ({item['points']:g} 分)", number), p(q["prompt"])]
        block.extend(p(f"{label}. {value}") for label, value in q.get("options", {}).items())
        if answers:
            block.extend([p("答案：" + q["answer"]), p(q["explanation"])])
            block.extend(p("评分要点：" + point) for point in q.get("rubric", []))
            refs = dict.fromkeys(f"{r['material_id']} 第 {r['page']} 页" for r in q["source_refs"])
            block.append(p("来源：" + "；".join(refs), source))
        else:
            block.extend([p("作答：__________________________________________________"), Spacer(1, 18)])
        flow.append(KeepTogether(block))
    document = SimpleDocTemplate(
        str(path),
        pagesize=A4,
        rightMargin=44,
        leftMargin=44,
        topMargin=40,
        bottomMargin=40,
        title=title,
        author="啄知 AI",
    )
    document.build(flow)
