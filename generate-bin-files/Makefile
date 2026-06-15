CXX=c++
CXXFLAGS=-std=c++23
LDFLAGS=-l curl -l simdjson

# out: gen-combined-whencaniuse-data-file

# gen-combined-whencaniuse-data-file: gen-combined-whencaniuse-data-file.cpp
# 	$(CXX) $(CXXFLAGS) $< $(LDFLAGS) -o $@

build: gen

gen: parse-bcd-json.cpp parse-caniuse-support-html.cpp caniuse.hpp
	$(CXX) $(CXXFLAGS) parse-bcd-json.cpp parse-caniuse-support-html.cpp $(LDFLAGS) -o $@


# old:

# build: parse-and-gen.exe

# parse-and-gen.exe: parse-and-gen.cpp
# 	cl parse-and-gen.cpp /std:c++17
