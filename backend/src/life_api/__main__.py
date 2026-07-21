import uvicorn

uvicorn.run("life_api.main:app", host="127.0.0.1", port=8080, reload=True)
