extends SceneTree
func _init():
    var cl = CanvasLayer.new()
    print("Has hide: ", cl.has_method("hide"))
    quit()
