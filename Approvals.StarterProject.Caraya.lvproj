<?xml version='1.0' encoding='UTF-8'?>
<Project Type="Project" LVVersion="20008000">
	<Property Name="NI.LV.All.SaveVersion" Type="Str">20.0</Property>
	<Property Name="NI.LV.All.SourceOnly" Type="Bool">true</Property>
	<Item Name="My Computer" Type="My Computer">
		<Property Name="NI.SortType" Type="Int">3</Property>
		<Property Name="server.app.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="server.control.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="server.tcp.enabled" Type="Bool">false</Property>
		<Property Name="server.tcp.port" Type="Int">0</Property>
		<Property Name="server.tcp.serviceName" Type="Str">My Computer/VI Server</Property>
		<Property Name="server.tcp.serviceName.default" Type="Str">My Computer/VI Server</Property>
		<Property Name="server.vi.callsEnabled" Type="Bool">true</Property>
		<Property Name="server.vi.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="specify.custom.address" Type="Bool">false</Property>
		<Item Name="Simple Tests" Type="Folder">
			<Item Name="Verify Hello World.vi" Type="VI" URL="../Caraya.Tests/Simple Tests/Verify Hello World.vi"/>
			<Item Name="Verify Hello World.approved.txt" Type="Document" URL="../Caraya.Tests/Simple Tests/Verify Hello World.approved.txt"/>
		</Item>
		<Item Name="lib_Caraya.Extension.lvlib" Type="Library" URL="/&lt;vilib&gt;/SAS/Approval Tests/Extensions/Caraya.Extension/lib_Caraya.Extension.lvlib"/>
		<Item Name="Run Simple Tests.vi" Type="VI" URL="../Caraya.Tests/Run Simple Tests.vi"/>
		<Item Name="Run All Tests.vi" Type="VI" URL="../Caraya.Tests/Run All Tests.vi"/>
		<Item Name="Dependencies" Type="Dependencies"/>
		<Item Name="Build Specifications" Type="Build"/>
	</Item>
</Project>
