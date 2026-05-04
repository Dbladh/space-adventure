extends SceneTree
func _init():
    var n = Node.new()
    root.add_child(n)
    var cl = CanvasLayer.new()
    cl.add_to_group("GameHUD")
    n.add_child(cl)
    set_group("GameHUD", "visible", false)
    print("CL visible after set_group: ", cl.visible)
    quit()
