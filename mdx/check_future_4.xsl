<?xml version="1.0" encoding="UTF-8"?>
<!--

	check_future_4.xsl
	
	Checking ruleset containing rules that we don't currently implement,
	but which we may implement in the future.
	
	Author: Ian A. Young <ian@iay.org.uk>

-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:ds="http://www.w3.org/2000/09/xmldsig#"
	xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"
	xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
	xmlns:shibmd="urn:mace:shibboleth:metadata:1.0"
	xmlns:set="http://exslt.org/sets"
	xmlns:wayf="http://sdss.ac.uk/2006/06/WAYF"
	xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
	xmlns:idpdisc="urn:oasis:names:tc:SAML:profiles:SSO:idp-discovery-protocol"

	xmlns:mdxURL="xalan://uk.ac.sdss.xalan.md.URLchecker"

	xmlns="urn:oasis:names:tc:SAML:2.0:metadata">

	<!--
		Common support functions.
	-->
	<xsl:import href="../build/check_framework.xsl"/>

	<xsl:template match="md:ArtifactResolutionService
		[@Binding != 'urn:oasis:names:tc:SAML:1.0:bindings:SOAP-binding']
		[@Binding != 'urn:oasis:names:tc:SAML:2.0:bindings:SOAP']
		">
		<xsl:call-template name="error">
			<xsl:with-param name="m">
				<xsl:text>invalid binding '</xsl:text>
				<xsl:value-of select="@Binding"/>
				<xsl:text>' on </xsl:text>
				<xsl:value-of select="name()"/>
			</xsl:with-param>
		</xsl:call-template>
	</xsl:template>
	
</xsl:stylesheet>