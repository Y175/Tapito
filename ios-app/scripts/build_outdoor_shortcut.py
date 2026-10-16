#!/usr/bin/env python3
"""Build the reviewable outdoor workflow and sign it with Apple's Shortcuts CLI.

The app intents do not toggle radios. The system action after offline connection
restores airplane mode BEFORE checking the result. OS cancellation/termination
can still interrupt this sequence; the import UI explains manual recovery.
"""
import argparse
import plistlib
import subprocess
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = "Tapito 户外初始化"


def identifier(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "https://tapito.local/outdoor/v1/" + name)).upper()


def output(intent, label):
    """A whole-value attachment, used by the conditional action's input selector."""
    return {"WFSerializationType": "WFTextTokenAttachment", "Value": {
        "Type": "ActionOutput", "OutputUUID": identifier(intent), "OutputName": label}}


def text_output(intent, label):
    """Text parameters require a token string; a bare attachment is discarded on import."""
    return {"WFSerializationType": "WFTextTokenString", "Value": {
        "string": "\ufffc", "attachmentsByRange": {"{0, 1}": output(intent, label)["Value"]}}}


def workflow(team):
    bundle = "com.y175.tapito"
    actions = []

    def action(name, **parameters):
        actions.append({"WFWorkflowActionIdentifier": name, "WFWorkflowActionParameters": parameters})

    def intent(name, **parameters):
        action(bundle + "." + name, AppIntentDescriptor={"AppIntentIdentifier": name,
            "BundleIdentifier": bundle, "TeamIdentifier": team, "Name": "Tapito"},
            UUID=identifier(name), ShowWhenRun=False, **parameters)

    action("is.workflow.actions.comment", WFCommentActionText=
        "Tapito 户外初始化 v2。编号、回执和结果已自动关联，无需填写。首次请在 Tapito 启用内置 VPN、完成配对和后台定位授权。"
        "保持解锁；中途手动停止或系统中断时，请自行关闭飞行模式。只初始化连接，不录音、不执行任务。")
    intent("PrepareOutdoorConnectionIntent")
    token = output("PrepareOutdoorConnectionIntent", "初始化编号")
    group = identifier("ready-branch")
    action("is.workflow.actions.conditional", GroupingIdentifier=group, WFControlFlowMode=0,
           WFCondition=4, WFConditionalActionString="ready", WFInput={"Type": "Variable", "Variable": token})
    action("is.workflow.actions.showresult", Text="Tapito 操控连接已就绪，无需切换飞行模式")
    action("is.workflow.actions.conditional", GroupingIdentifier=group, WFControlFlowMode=1)
    action("is.workflow.actions.airplanemode.set", OnValue=True)
    intent("ConnectOutdoorOfflineIntent", ticket=text_output("PrepareOutdoorConnectionIntent", "初始化编号"))
    action("is.workflow.actions.airplanemode.set", OnValue=False)
    intent("FinishOutdoorConnectionIntent", receipt=text_output("ConnectOutdoorOfflineIntent", "离线连接回执"))
    action("is.workflow.actions.showresult", Text=text_output("FinishOutdoorConnectionIntent", "连接结果"))
    action("is.workflow.actions.conditional", GroupingIdentifier=group, WFControlFlowMode=2)
    return {"WFWorkflowName": NAME, "WFWorkflowClientVersion": "4000", "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59752},
            "WFWorkflowTypes": [], "WFQuickActionSurfaces": [], "WFWorkflowInputContentItemClasses": [],
            "WFWorkflowImportQuestions": [], "WFWorkflowActions": actions}


def validate(value):
    """Reject broken radio ordering and missing/dangling text bindings before signing."""
    actions = value["WFWorkflowActions"]
    ids = [a["WFWorkflowActionIdentifier"] for a in actions]
    if (len(actions) != 11 or ids[1] != "com.y175.tapito.PrepareOutdoorConnectionIntent"
        or actions[2]["WFWorkflowActionParameters"]["WFConditionalActionString"] != "ready"
        or ids[5:10] != ["is.workflow.actions.airplanemode.set", "com.y175.tapito.ConnectOutdoorOfflineIntent",
                        "is.workflow.actions.airplanemode.set", "com.y175.tapito.FinishOutdoorConnectionIntent",
                        "is.workflow.actions.showresult"]
        or actions[5]["WFWorkflowActionParameters"]["OnValue"] is not True
        or actions[7]["WFWorkflowActionParameters"]["OnValue"] is not False
        or ids.count("is.workflow.actions.airplanemode.set") != 2):
        raise ValueError("Outdoor workflow must restore airplane mode before checking the connection result")
    # There must be no throw-prone result parsing or conditional action between offline work and restoration.
    for index, key, source in [(6, "ticket", 1), (8, "receipt", 6), (9, "Text", 8)]:
        binding = actions[index]["WFWorkflowActionParameters"].get(key, {})
        body = binding.get("Value", {})
        attachments = body.get("attachmentsByRange", {})
        reference = attachments.get("{0, 1}", {})
        if (binding.get("WFSerializationType") != "WFTextTokenString"
            or body.get("string") != "\ufffc" or set(attachments) != {"{0, 1}"}
            or reference.get("Type") != "ActionOutput"
            or reference.get("OutputUUID") != actions[source]["WFWorkflowActionParameters"]["UUID"]):
            raise ValueError(f"Action {index} parameter {key} must reference action {source} as a text variable")
    condition = actions[2]["WFWorkflowActionParameters"]["WFInput"]
    if condition != {"Type": "Variable", "Variable": output("PrepareOutdoorConnectionIntent", "初始化编号")}:
        raise ValueError("The ready branch must reference the preparation result")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--team", required=True)
    parser.add_argument("--unsigned-only", action="store_true")
    args = parser.parse_args()
    value = workflow(args.team)
    validate(value)
    source = ROOT.parent / ".build/connection/Tapito-Outdoor.unsigned.shortcut"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=False))
    if not args.unsigned_only:
        destination = ROOT / "Tapito/ConnectionResources" / (NAME + ".shortcut")
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(source),
                        "--output", str(destination)], check=True)
        print(destination)
    else:
        print(source)
